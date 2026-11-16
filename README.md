# onn 4K Pro Lossless Audio Passthrough

A Magisk module that enables **Dolby TrueHD/Atmos** and **DTS-HD Master Audio/DTS:X**
passthrough over HDMI on the onn 4K Pro (2026).

Out of the box the onn converts everything to Dolby Digital Plus (or PCM) before
it leaves the box, so you lose the lossless audio. The hardware supports it
fine — it's gated in the firmware. This module removes those gates.

It also brings back a few sound settings onn hid:

- a proper **Passthrough** mode you can switch on and off in Settings
- **Dolby DRC** (Line / RF) and **DTS DRC** (on / off)
- **Dolby preferred output** (MAT or DD+)

## Tested on

| | |
|---|---|
| Device | onn 4K Pro Streaming Device (2026), codename `jarvis2` |
| Chip | Amlogic S905X5M |
| Android | Android TV 14 (API 34) |
| Firmware | `URO3.260203.035.A1.15640252` |
| Kernel | `5.15.196-android14-11-g3d26c188ef7e-ab14657224` |
| Magisk | 30.7 |

The module only installs on that exact firmware. On anything else it tells you
it's not supported and doesn't change anything. If you get it working on
another firmware, open an issue.

## Install

1. Root your onn 4K Pro with Magisk.
2. Flash `onn-lossless-passthrough-v2.0.zip` in Magisk and reboot.
3. About a minute after boot, the sound cuts out briefly as the module kicks in.
4. The module automatically sets Passthrough mode. Your receiver should show
   TrueHD Atmos or DTS-HD MA when playing lossless content.

To change the audio mode: **Settings > Display & Sound > Audio output mode**.

To turn it off: disable or remove the module in Magisk and reboot.

To build the zip yourself, run `python3 build-zip.py`.

## How it works

Nothing on the system is permanently modified. Everything happens in memory
after the box boots and is gone on the next reboot if the module is off.

### TrueHD / Atmos

Based on [Spark-NV's original work](https://github.com/Spark-NV/ONN4k-TrueHD):

- The HDMI multichannel audio link was capped at 96 kHz. TrueHD needs 192 kHz.
  A small kernel module (`t9015rate.ko`) raises that limit in memory.
- The firmware already has a TrueHD switch
  (`ro.vendor.platform.is.aml_truehd_passthrough`), it's just turned off. The
  module turns it on and turns off the "always DD+" flag.
- TrueHD gets added to the surround format list in the audio policy XML.

### DTS-HD MA / DTS:X

Two binary patches to `audio.primary.amlogic.so`:

1. **`hdmi_encodings` handler** (34 bytes at file offset `0x7ab9a`): the HAL's
   `adev_get_parameters("hdmi_encodings")` response drives the DroidLogic
   framework's format detection. Stock code checks AC3, E_AC3, and Atmos but
   skips DTS-HD. This patch replaces dead logging code with a check of the
   DTS-HD EDID capability flag and appends `"dtshd;"` to the response.

2. **`sup_formats` gate** (2-byte NOP at file offset `0x86f22`): the HAL reads
   DTS-HD support from EDID and logs it, but gates adding `AUDIO_FORMAT_DTS_HD`
   to the `sup_formats` response behind a DTS decode library flag. NOPing the
   conditional branch makes the report unconditional, so Android's
   AudioPolicyManager creates a DTS-HD dynamic profile on HDMI Out.

### Shared

- Mounts `aml_audio_config.json` with `Passthrough_Audio_Config: 1` to unlock
  Passthrough and DRC options in onn's audio menu.
- Sets DroidAudio mode 3 (Passthrough) so the HAL sends bitstreams raw instead
  of re-encoding through MS12.
- A new **Audio output mode** row in Display & Sound takes you to onn's sound
  menu (via the Settings overlay).

### Regenerating the patched HAL

```
python3 patch_hal.py
```

Reads the stock `audio.primary.amlogic.so` and writes the patched version. The
script verifies expected bytes at each patch site before writing.

## Other settings it unlocks

In the same **Audio output mode** menu:

- **Dolby DRC Mode**: squashes the loud and quiet parts closer together. RF
  squashes more than Line, which is handy at night.
- **DTS DRC Mode**: the same thing for DTS.
- **Dialog Enhancer** and **Downmix Mode** were already there, there just
  wasn't any way to get to the menu.

Under **Settings > Display & Sound > Audio options**:

- **Dolby preferred output**: whether the box sends Dolby MAT or Dolby Digital
  Plus when it's re-encoding audio itself in Automatic mode.

These only matter when the box is decoding or re-encoding. In Passthrough the
audio goes out exactly as it is in the file.

The Magisk **Action** button opens the sound menu and shows module status.
The log is at `/data/adb/onn_lossless/apply.log`.

## What doesn't work

- **96 kHz TrueHD** (rare, mostly music and some test files) plays as stereo
  PCM. That's Dolby's own code on the box failing. 48 kHz TrueHD, which is what
  movies use, works fine.
- While lossless audio is playing in Passthrough you won't hear menu click
  sounds. That's normal for any box doing lossless passthrough.

## Removing it

Disable or remove it in Magisk and reboot. If you can't get into Magisk,
`adb shell su -c magisk --remove-modules` and reboot.

Your audio output mode setting stays saved. If it was on Passthrough, the stock
firmware goes back to sending DD+, so nothing breaks.

## Source

- `module/` is the Magisk module itself.
- `module/hal/` contains the patched audio HAL binary.
- `patch_hal.py` regenerates the patched HAL from the stock binary.
- `src/kernel/` is the kernel helper (`t9015rate.ko`) and how to build it.
- `src/overlay/` is the Settings row overlay and its build script.

## Credits

- [Spark-NV](https://github.com/Spark-NV) for the original TrueHD passthrough
  module, kernel helper, and Settings overlay
- DTS-HD MA / DTS:X support by kushmint

The kernel helper is GPL-2.0.
