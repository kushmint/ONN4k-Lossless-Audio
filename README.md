# onn 4K Pro — Full Lossless Audio Passthrough

**Unlock the full potential of your onn 4K Pro's audio.** This Magisk module
enables **Dolby TrueHD/Atmos** and **DTS-HD Master Audio/DTS:X** bitstream
passthrough over HDMI — the lossless audio formats that Blu-ray and 4K UHD
movies were meant to be heard in.

Out of the box, the onn 4K Pro silently downgrades every lossless audio track
to lossy Dolby Digital Plus or plain PCM before it even reaches your receiver.
You're losing quality on every movie and you'd never know. The hardware is
perfectly capable of sending lossless audio — Amlogic just left it gated in the
firmware.

**This module removes every one of those gates.** One flash, one reboot, and
your $20 streaming box is sending the same bit-perfect lossless audio that
$200+ players do.

## What you get

- **Dolby TrueHD & Dolby Atmos** passthrough — the full lossless Dolby
  experience, not a compressed re-encode
- **DTS-HD Master Audio & DTS:X** passthrough — lossless DTS straight to your
  receiver, no more silent downgrade to DTS core
- **Zero configuration** — the module handles everything behind the scenes.
  Your surround sound settings (Auto / Manual / None) work exactly like stock
  Android. Auto detects what your amp supports and enables it
- **Fully reversible** — nothing is written to system partitions. Everything
  runs in memory. Disable the module and reboot to go back to stock
- **Bonus unlocks** — Dolby DRC, DTS DRC, and other hidden audio settings that
  onn left in the firmware but hid from the UI

## Supported formats

| Format | Stock onn behavior | With this module |
|---|---|---|
| Dolby TrueHD | Re-encoded to DD+ | Lossless passthrough |
| Dolby Atmos (TrueHD) | Re-encoded to DD+ | Lossless passthrough |
| DTS-HD Master Audio | Downgraded to DTS core | Lossless passthrough |
| DTS:X | Downgraded to DTS core | Lossless passthrough |
| Dolby Digital / DD+ | Passthrough (already works) | No change |
| DTS core | Passthrough (already works) | No change |

## Tested on

| | |
|---|---|
| Device | onn 4K Pro Streaming Device (2026), codename `jarvis2` |
| Chip | Amlogic S905X5M |
| Android | Android TV 14 (API 34) |
| Firmware | `URO3.260203.035.A1.15640252` |
| Kernel | `5.15.196-android14-11-g3d26c188ef7e-ab14657224` |
| Magisk | 30.7 |

The module only installs on the exact firmware listed above. On anything else
it tells you it's not supported and doesn't change anything. If you get it
working on another firmware, open an issue.

## Install

1. Root your onn 4K Pro with Magisk.
2. Flash `onn-lossless-passthrough-v2.0.zip` in Magisk and reboot.
3. About a minute after boot, the sound cuts out briefly as the module kicks in.
4. Done.

Your standard surround sound settings work exactly as you'd expect:

- **Auto**: the box queries your receiver's EDID, detects TrueHD and DTS-HD MA
  support, and enables them automatically
- **Manual**: TrueHD and DTS-HD MA now appear in the format list for you to
  select alongside DD, DD+, DTS, etc.
- **None**: PCM only, same as stock

Play a movie with a TrueHD Atmos or DTS-HD MA soundtrack and check your
receiver — it should show the full lossless format instead of a lossy
re-encode.

To build the zip yourself: `python3 build-zip.py`

## How it works

Nothing on the system is permanently modified. Everything happens in memory
after boot and is gone on the next reboot if the module is off.

### TrueHD / Atmos

Based on [Spark-NV's original work](https://github.com/Spark-NV/ONN4k-TrueHD):

- The HDMI audio link was capped at 96 kHz. TrueHD needs 192 kHz. A small
  kernel module (`t9015rate.ko`) raises that limit in memory.
- The firmware has a TrueHD passthrough switch
  (`ro.vendor.platform.is.aml_truehd_passthrough`), just turned off. The module
  flips it on and disables the "force DD+" flag.
- `AUDIO_FORMAT_DOLBY_TRUEHD` is added to the audio policy surround format list.

### DTS-HD MA / DTS:X

The stock HAL *detects* DTS-HD from the receiver's EDID and even logs it — but
then deliberately hides it from Android. Three binary patches to
`audio.primary.amlogic.so` fix this:

1. **`hdmi_encodings` handler** (34 bytes at offset `0x7ab9a`): the HAL's format
   detection response drives the DroidLogic framework. Stock code reports AC3,
   E_AC3, and Atmos to the framework but skips DTS-HD entirely. This patch
   replaces dead logging code with a DTS-HD capability check that appends
   `"dtshd;"` to the response, so the framework knows DTS-HD is available.

2. **`sup_formats` gate** (2-byte NOP at offset `0x86f22`): the HAL reports
   supported formats to Android's AudioPolicyManager. It correctly detects
   DTS-HD from EDID, but gates actually *reporting* it behind a DTS decode
   library flag. A single NOP removes that gate, so AudioPolicyManager creates
   a full DTS-HD dynamic profile on HDMI Out with proper sample rates and
   channel maps.

3. **`get_sink_format` AUTO→BYPASS** (1 byte each at offsets `0x8c6e2` and
   `0x8c680`): the HAL's output-format decision function checks the internal
   digital audio mode. Mode 6 (BYPASS) passes bitstreams raw; mode 4 (AUTO)
   re-encodes lossless to lossy. The framework always boots the HAL into AUTO
   mode. This patch changes `CMP r0,#6` to `CMP r0,#4` so AUTO takes the
   BYPASS code path — DTS-HD/DTS:X/TrueHD pass through raw when the receiver
   supports them, with graceful fallback to lossy otherwise.

The module also adds `AUDIO_FORMAT_DTS_HD` as a static profile in the audio
policy XML's `compress offload` and `ms12 direct` mixPorts, as a belt-and-
suspenders alongside the dynamic profile from patch 2.

All three patches together mean DTS-HD MA becomes a first-class citizen in the
audio pipeline — visible to Android, visible to the framework, and passing
through raw to your receiver.

### Regenerating the patched HAL

```
python3 patch_hal.py
```

Reads the stock `audio.primary.amlogic.so` and writes the patched version. The
script verifies expected bytes at each patch site before writing, so it won't
silently produce a broken binary on the wrong input.

## Other settings it unlocks

The module also enables hidden audio options that onn left in the firmware:

- **Dolby DRC Mode** (Line / RF) — dynamic range compression for late-night
  listening
- **DTS DRC Mode** (on / off) — same for DTS content
- **Dialog Enhancer** and **Downmix Mode** — were already there, just had no
  menu path

## Known limitations

- **96 kHz TrueHD** (rare — mostly music and test files) plays as stereo PCM.
  That's Dolby's own code on the box. 48 kHz TrueHD, which is what movies use,
  works fine.
- **System sounds are silent during lossless playback.** That's normal for any
  device doing bitstream passthrough — the HDMI link is carrying a raw encoded
  stream, so PCM system sounds can't be mixed in. They come back as soon as
  playback stops.

## Removing it

Disable or remove it in Magisk and reboot. If you can't get into Magisk:

```
adb shell su -c magisk --remove-modules
```

Then reboot. The stock firmware goes back to sending DD+/DTS core, nothing
breaks.

## Source

- `module/` — the Magisk module
- `module/hal/` — the patched audio HAL binary
- `patch_hal.py` — reproduces the patched HAL from the stock binary
- `src/kernel/` — the 192 kHz kernel helper and how to build it
- `src/overlay/` — the Settings overlay and its build script

## Credits

- [Spark-NV](https://github.com/Spark-NV) for the original TrueHD passthrough
  module, kernel helper, and Settings overlay
- DTS-HD MA / DTS:X passthrough by [kushmint](https://github.com/kushmint)

The kernel helper is GPL-2.0.
