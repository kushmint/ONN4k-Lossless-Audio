#!/usr/bin/env python3
"""Patch /vendor/lib/libamladecs.so (Amlogic decoder wrapper) for DTS-HD passthrough.
file_offset = VA - 0x10000 (text). Function: dca_decoder_process_patch @ 0x16124.
Raw-output block hard-codes: inner format = AUDIO_FORMAT_DTS (0xb000000) and clamps raw sample
rate to 48000/44100. We change inner format to DTS_HD (0xc000000) and remove the clamp so the
decoder lib's fmt[0] (192000, 4x carrier) reaches the HAL.
usage: patch_amladecs.py in.so out.so"""
import sys, hashlib
PATCHES = [
  (0x6490, bytes.fromhex("4ff03060"), bytes.fromhex("4ff04060")),  # MOV.W R0,#0xB000000 -> #0xC000000
  (0x64b6, bytes.fromhex("0221"), bytes.fromhex("0821")),  # MOVS R1,#2 -> #8: raw ch=8 => select_digital_device picks HBR device 2
  (0x64be, bytes.fromhex("18bf4bf68033"), bytes.fromhex("00bf00bf00bf")),  # IT NE; MOVWNE R3,#0xBB80 -> NOPs
]
src, dst = sys.argv[1:3]
d = bytearray(open(src,"rb").read())
assert len(d) == 69612, "unexpected size %d" % len(d)
for off, old, new in PATCHES:
    assert d[off:off+len(old)] == old, "bytes at %#x are %s, expected %s" % (off, d[off:off+len(old)].hex(), old.hex())
    d[off:off+len(new)] = new
open(dst,"wb").write(d)
print("patched ->", dst, hashlib.sha256(d).hexdigest()[:16])
