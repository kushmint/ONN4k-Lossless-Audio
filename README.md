# onn 4K Pro — Full Lossless Audio Passthrough

### ⬇️ [Download onn-lossless-passthrough-v2.1.zip](https://github.com/kushmint/ONN4k-Lossless-Audio/releases/latest/download/onn-lossless-passthrough-v2.1.zip)
Flash it in Magisk and reboot. [All releases](https://github.com/kushmint/ONN4k-Lossless-Audio/releases)

---

**Unlock the full potential of your onn 4K Pro's audio.** This Magisk module
enables **Dolby TrueHD/Atmos** and **DTS-HD Master Audio/DTS:X** bitstream
passthrough over HDMI — the lossless audio formats that Blu-ray and 4K UHD
movies were meant to be heard in.

Out of the box, the onn 4K Pro silently downgrades every lossless audio track
to lossy Dolby Digital Plus or plain PCM before it even reaches your receiver.
You're losing quality on every movie and you'd never know. The hardware is
perfectly capable of sending lossless audio — Amlogic just left it gated in the
firmware.

**This module removes those gates.** One flash, one reboot, and your $20
streaming box sends the same bit-perfect lossless audio that $200+ players do.

## What you get

- **Dolby TrueHD & Dolby Atmos** passthrough — the full lossless Dolby
  experience, not a decode-and-re-wrap
- **DTS-HD Master Audio & DTS:X** passthrough — real lossless DTS (HDMI
  high-bit-rate), not the DTS core downgrade
- **Zero configuration** — the module handles everything behind the scenes
  after each boot
- **Fully reversible** — nothing is written to system partitions. Everything
  runs in memory. Disable the module and reboot to go back to stock
- **Bonus unlocks** — Dolby DRC, DTS DRC, and other hidden audio settings that
  onn left in the firmware but hid from the UI

## Supported formats

| Format | Stock onn behavior | With this module |
|---|---|---|
| Dolby TrueHD | Re-encoded to DD+ | Lossless passthrough |
| Dolby Atmos (TrueHD) | Re-encoded to DD+ | Lossless passthrough |
| DTS-HD Master Audio | Downgraded to DTS core | **Lossless passthrough** |
| DTS:X | Downgraded to DTS core | **Lossless passthrough** |
| Dolby Digital / DD+ | Passthrough | Passthrough (checked) |
| DTS core only | Passthrough | **Not yet tested with v2.1** — see Known limitations |

## Tested on

| | |
|---|---|
| Device | onn 4K Pro Streaming Device (2026), codename `jarvis2` |
| Chip | Amlogic S905X5M |
| Android | Android TV 14 (API 34) |
| Firmware | `URO3.260203.035.A1.15640252` |
| Kernel | `5.15.196-android14-11-g3d26c188ef7e-ab14657224` |
| Magisk | 30.7 |

There are two audio HAL builds in the wild on this firmware (the Canadian unit
and the US unit differ). The module ships a patched HAL for each and picks the
right one by the stock HAL's SHA-256. On anything it doesn't recognise it
installs nothing and changes nothing.

| Unit | Audio HAL (stock sha256) | Status |
|---|---|---|
| Canadian | `139a5fd5…` | Fully tested: DTS-HD MA, DTS:X, TrueHD, DD+ |
| US | `bc26b0cd…` | Patched HAL included; installs and boots clean. Playback reports welcome |

If you get it working on another firmware, open an issue.

## Install

1. Root your onn 4K Pro with Magisk.
2. Flash `onn-lossless-passthrough-v2.1.zip` in Magisk and reboot.
3. About a minute after boot, the sound cuts out briefly as the module kicks in.
4. Done.

If you have the older "TrueHD/Atmos Passthrough" module installed, disable it
first — the two modules patch the same files and can't both be active.

Play a movie with a TrueHD Atmos or DTS-HD MA soundtrack and check your
receiver — it should show the full lossless format instead of PCM or a lossy
re-encode. Use a player that sends the bitstream out (Nova, Kodi, VLC,
Syncler/ExoPlayer all do).

To build the zip yourself: `python3 build-zip.py`

## How it works

Nothing on the system is permanently modified. Everything happens in memory
after boot and is gone on the next reboot if the module is off.

### Real Passthrough mode

The HAL has an internal digital-audio mode: Auto (4) or Bypass (6). In Auto,
Dolby's MS12 engine **decodes TrueHD to 8-channel PCM and re-wraps it as MAT 2.0
(PCM)** — your receiver shows "Dolby Surround PCM". The TrueHD bypass
(`dolby_truehd_bypass_process` → MAT encoder → HDMI) is keyed to Bypass mode in
a dozen places, so the module sets the HAL to **Passthrough (Bypass)** after
boot. That one change is what makes TrueHD/Atmos a true bitstream.

### TrueHD / Atmos

- The HDMI audio link was capped at 96 kHz. TrueHD needs 192 kHz. A small
  kernel module (`t9015rate.ko`) raises that limit in memory.
- The firmware has a TrueHD passthrough switch
  (`ro.vendor.platform.is.aml_truehd_passthrough`), just turned off. The module
  flips it on and disables the "force DD+" flag.
- `AUDIO_FORMAT_DOLBY_TRUEHD` is added to the audio policy surround format list.

### DTS-HD MA / DTS:X

Four pieces, all applied in memory at boot:

**1. Make Android see DTS-HD (two patches to `audio.primary.amlogic.so`).**
The stock HAL *detects* DTS-HD from the receiver's EDID — then hides it.

- `hdmi_encodings` handler (34 bytes): replaces dead logging code with a
  DTS-HD capability check that appends `"dtshd;"` to the response, so the
  DroidLogic framework knows DTS-HD is available.
- `sup_formats` gate (2-byte NOP): removes the check that stopped DTS-HD being
  reported to AudioPolicyManager, so a full DTS-HD profile appears on HDMI Out.

The module also adds `AUDIO_FORMAT_DTS_HD` / `AUDIO_FORMAT_DTS` profiles to the
audio policy XML (`compress offload`, `ms12 direct`, and the HDMI Out device
port) so apps see them in `AudioDeviceInfo.getEncodings()`.

**2. Send the *whole* DTS-HD stream, not just the core.** The stock DTS
"decoder" (`libHwAudio_dtshd.so`, SoftDCA) only strips the DTS core
(~1.5 Mbps) out of a DTS-HD MA stream and frames it. The module mounts a
replacement (`src/dtshd/dtshd_passthrough.c`) that follows the stock library's
ABI — recovered by disassembly — and instead builds an **IEC 61937-5 type IV
(DTS-HD) HBR burst** around the complete core+extension access unit:
`F872 4E1F | Pc=0x0411 | Pd | 01 00 … FE FE | length | DTS data`, padded to 32768
bytes per 512-sample frame (8 channels × 192 kHz × 16 bit).

**3. Tell the HAL it's a DTS-HD HBR stream (three patches to `libamladecs.so`).**
The Amlogic decoder wrapper hard-codes the passthrough stream as plain DTS,
stereo, 48 kHz. Three byte-verified patches, made **at boot to your device's own
copy** (and skipped if the bytes aren't what's expected):

- inner format `DTS` → `DTS_HD`
- channel count `2` → `8` (this is what routes it to the HDMI HBR device)
- remove the 48 kHz sample-rate clamp so 192 kHz reaches the HAL

**4. HDMI side.** The HAL opens the HBR device (192 kHz × 8 ch), the kernel
HDMI transmitter is told `CT_DTS_HD`, and the receiver locks to DTS-HD MA.

### Regenerating the pieces

```
python3 patch_hal.py <stock-CA-HAL> <out>      # Canadian HAL, patches 1+2
python3 patch_hal_us.py <stock-US-HAL> <out>   # US HAL, patches 1+2
sh src/dtshd/build.sh                          # replacement DTS decoder (needs clang)
python3 src/dtshd/patch_amladecs.py <in> <out> # same wrapper patches the module makes at boot
```

Every script verifies the expected bytes at each patch site before writing, so
it won't silently produce a broken binary on the wrong input. The full
reverse-engineering notes are in [`src/dtshd/NOTES.md`](src/dtshd/NOTES.md).

## Other settings it unlocks

The module also enables hidden audio options that onn left in the firmware:

- **Dolby DRC Mode** (Line / RF) — dynamic range compression for late-night
  listening
- **DTS DRC Mode** (on / off) — same for DTS content
- **Dialog Enhancer** and **Downmix Mode** — were already there, just had no
  menu path

## Known limitations

- **DTS core-only tracks** (plain DTS 5.1, no HD extension) are sent as a DTS-HD
  burst by the replacement decoder. That hasn't been verified against a
  receiver yet — if you have a plain-DTS file, please test and report.
- **96 kHz TrueHD** (rare — mostly music and test files) plays as stereo PCM.
  That's Dolby's own code on the box. 48 kHz TrueHD, which is what movies use,
  works fine.
- **System sounds are silent during lossless playback.** That's normal for any
  device doing bitstream passthrough — the HDMI link is carrying a raw encoded
  stream, so PCM system sounds can't be mixed in. They come back as soon as
  playback stops.
- The module sets the HAL to Passthrough mode at boot, so the box behaves as
  "passthrough" for every format your receiver supports.

## Removing it

Disable or remove it in Magisk and reboot. If you can't get into Magisk:

```
adb shell su -c magisk --remove-modules
```

Then reboot. The stock firmware goes back to sending DD+/DTS core, nothing
breaks.

## Source

- `module/` — the Magisk module
- `module/hal/` — the patched audio HALs (Canadian and US) and the replacement DTS decoder
- `module/common/dtshd.sh` — boot-time patching/mounting of the DTS-HD pieces
- `patch_hal.py`, `patch_hal_us.py` — reproduce the patched HALs from the stock binaries
- `src/dtshd/` — replacement DTS decoder source, wrapper patcher, and reverse-engineering notes
- `src/kernel/` — the 192 kHz kernel helper and how to build it
- `src/overlay/` — the Settings overlay and its build script

## Credits

- [Spark-NV](https://github.com/Spark-NV) for the original TrueHD passthrough
  module, kernel helper, and Settings overlay
- DTS-HD MA / DTS:X lossless passthrough, the TrueHD bypass fix, and US-unit
  support by [kushmint](https://github.com/kushmint)

The kernel helper is GPL-2.0.
