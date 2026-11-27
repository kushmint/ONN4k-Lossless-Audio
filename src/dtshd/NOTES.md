# DTS-HD replacement decoder notes (2026-11-18)

**Ignore the old local context.txt analysis**: the 3,568-byte "stock" lib it analyzes is our own v7/v8
test build (bind-mounted on the device). Real stock SoftDCA v2.1.0 is 22,152 bytes on the /odm erofs image
(dev box: `mount -t erofs -o ro /dev/block/dm-13 <dir>` to read it under the bind mounts).

## Stock dca_decoder_process ABI (disassembled, stock 0x22f0)
    int f(in, in_size, int *consumed, out_buf, int *out_size0, int *fmt, out_buf2, int *out_size1)
    success path: *out_size0 = *out_size1 = iec_len
                  memset(out_buf, 0, iec_len)           // PCM silence carrier
                  fmt[0] = sample_rate (48000 default), fmt[1] = 2 (channels)   // only 8 bytes
                  IEC61937 frame written into out_buf2
                  *consumed = in_size; return in_size
`hw_write ch=0` was because v5-v8 never filled `fmt`. v9+ do, and that error is gone.

## v9/v10 results (the dev box, DTS-HD MA test mkv)
- v9: fmt=48000/2, Pc=0x11 burst. AVR shows DTS-HD Hi-Res, video laggy (bursts 2-5 KB vs 48k stereo pipe).
- v10: fmt[0]=192000. Video smooth, AVR "Hi-Res", NO sound. HAL ignores fmt[0] for ALSA rate: still
  `pcm_open card=0 device=4 rt=48000 ch=2 period=1024*8`.
- Root cause of silence: HAL opens spdifout with `audio_format 0xb000000` (AUDIO_FORMAT_DTS, core), spdif
  format 0x3, ch 0x3 (`select_digital_device`/`aml_audio_spdifout_open`), i.e. channel status says DTS type I
  at 48k while our payload is a type-IV burst the sink cannot lock to.
- The format (0xb000000 vs DTS_HD 0xc000000) is chosen by the HAL, not by the decoder lib. The lib alone
  cannot get HBR; a HAL patch (make spdifout use DTS_HD + HBR/8ch device) is needed.

## Next steps
1. Sanity: type-I core-only burst from our lib should give sound again (matches stock behavior).
2. HAL patch: find where aml_out/spdifout audio_format is set to DTS (0xb000000) after dts_decoder_config_prepare
   and force DTS_HD (0xc000000) + HBR device. Needs Ghidra (not installed) or capstone.

## SOLVED (v14 + patched libamladecs) - DTS-HD MA lossless over HDMI HBR, confirmed on the dev box
Pipeline that works:
1. libamladecs.so patched by patch_amladecs.py (3 patches, file off = VA-0x10000, dca_decoder_process_patch):
   - 0x6490  MOV.W R0,#0xB000000 -> #0xC000000   (raw inner format DTS -> DTS_HD)
   - 0x64b6  MOVS R1,#2 -> #8                      (raw channels 8 => select_digital_device returns HBR device 2)
   - 0x64be  IT NE; MOVWNE R3,#0xBB80 -> 3x NOP    (remove 48k clamp so fmt[0]=192000 reaches HAL)
2. libHwAudio_dtshd.so v14 (dtshd_passthrough.c): stock ABI, PCM carrier 8192 B silence (fmt 192000/2ch),
   raw burst 32768 B = IEC61937-5 type IV: F872 4E1F | Pc=0x0411 (subtype 4: 8192-sample period @768k) | Pd |
   01 00 00 00 00 00 00 00 FE FE | len16 | DTS core+ext AU | zero pad, 16-bit byte-swapped for S16LE.
   v13 (Pc=0x0011, subtype 0) and v12 (no 10-byte start code/len) did NOT work: AVR said "multi ch", no sound.
3. HAL then opens card0 device1 (TDM-B/i2s2hdmi) 192k x 8ch, kernel hdmitx: CT_DTS_HD type 267, same as CT_MAT path.
Gotchas: use a player doing DTS-HD passthrough (Syncler/ExoPlayer ok); don't power-cycle AVR while testing (HDMI re-probe).

## TrueHD fix (2026-11-18): real Passthrough mode, drop patch 3
Symptom (v2.0, Auto mode + patch 3): TrueHD played as "Dolby Digital Surround PCM". MS12 *decoded* TrueHD
(THD node, decoded acmod 7, volume_process s32Channel 8) and re-wrapped it as MAT 2.0 (PCM).
Cause: the MS12 TrueHD bypass (aml_audio_ms12_process_wrapper -> dolby_ms12_bypass_process ->
dolby_truehd_bypass_process -> MAT encoder -> spdifout) is keyed to adev+0x194 == 6 (BYPASS) in many places
(is_ms12_passthrough, dolby_ms12_main_process, ...). Patch 3 only made get_sink_format treat AUTO as BYPASS.
Patching 6 more CMP sites (AUTO->6) did NOT help. The original onn_truehd_passthrough module (on the US box)
ships no HAL patch at all: it relies on the user selecting Audio output mode = Passthrough.
Fix: HAL patches 1+2 only (no patch 3/4) + DroidAudio mode 3 (Passthrough -> HAL BYPASS). Verified on the dev box:
TrueHD and DTS-HD MA both play as bitstreams. Shipped CA HAL sha 2aaf7413..., US HAL 5a9b8238... (US untested).

## v15 (2026-11-27): per-frame burst timing (44.1 kHz DTS fix)
Reddit report: "DTS 5.1 48 kHz breaking up, DTS x96 fine; AAC 5.1/7.1 don't play". Tested on the dev box (Denon AVR):
- 48 kHz DTS core and DTS-HD MA: clean in Just Player (ExoPlayer, raw DTS -> this lib) and in Kodi (Kodi's own
  IEC packer -> AUDIO_FORMAT_IEC61937 -> HAL iec_passthrough, which never touches this lib). Not reproduced.
- 44.1 kHz DTS core: **silent** with v14. v14 always declared a 192 kHz link + subtype 4 (8192-sample period),
  i.e. 512 samples @ 48 kHz, so the burst rate was wrong for anything else.
- v15 parses the core header (NBLKS, SFREQ): link 192000 (48k family) / 176400 (44.1k family) via fmt[0], period =
  samples * link*4/fs, subtype = log2(period/512), burst = period*4 B, carrier = period B. HAL accepts fmt[0]=176400
  (`pcm_open card=0 device=1 rt=176400 ch=8`), amp shows DTS, clean. 48k core / MA output is unchanged from v14
  except Pd is now padded so (Pd & 0xf) == 8 (ffmpeg spdifenc does this; "needed with some receivers").
- Not handled: periods > 8192 (e.g. 1024-sample 48 kHz frames would need a 65536 B burst; the wrapper's out_buf2
  size beyond 32 KB is unknown) -> v14 timing. 32 kHz has no integer HBR ratio -> v14 timing.
- No division in the lib: built -nostdlib, so __aeabi_idiv/uidiv are unresolved (table + shifts instead).
- AAC 5.1/7.1: 6/8-ch PCM_DIRECT opens on card0 device1 and plays in Just Player, Nova and Kodi. VLC 3.0.25 opens
  the DIRECT track and never writes a frame (server pos 0, track removed after ~2 s); identical with the module
  fully unmounted (stock HAL, AUTO), so it's VLC, not the module.
- Note: restarting vendor.audio-hal drops the HAL back to AUTO; re-push mode via DroidAudio call 21 (1, then 3).
