#!/usr/bin/env python3
"""
Patch audio.primary.amlogic.so to enable DTS-HD MA / DTS:X passthrough.

Two binary patches:

Patch 1 — hdmi_encodings handler (VA 0x9ab9a, 34 bytes)
  Replaces dead logging code with a check of the DTS_HD capability flag
  (HDMI cap struct offset 0x74) and appends "dtshd;" to the hdmi_encodings
  response string. Also overwrites a log format string at VA 0x47413
  with "dtshd;\0" so the literal pool entry already pointing there becomes
  the format argument for snprintf.

Patch 2 — sup_formats DTS_HD gate (VA 0xa6f22, 2 bytes)
  The HAL detects DTS-HD from EDID and logs it, but gates adding
  AUDIO_FORMAT_DTS_HD to the sup_formats response behind a check of the
  DTS decode library flag (adev->0x6c0 != 0). NOPing the CBZ makes the
  append unconditional, so AudioPolicyManager creates a DTS_HD dynamic
  profile on HDMI Out.

The stock HAL is 32-bit ARM (Thumb-2). Ghidra base address is 0x10000.
"""

import struct
import sys
import os
import hashlib

STOCK_SHA256 = None  # set after first successful patch to lock it down

def va_to_file(ghidra_va):
    if ghidra_va < 0x799e0:
        return ghidra_va - 0x10000
    elif ghidra_va < 0x1BE820:
        return ghidra_va - 0x20000
    else:
        return ghidra_va - 0x30000


def encode_thumb_b(from_addr, to_addr):
    offset = to_addr - (from_addr + 4)
    assert -2048 <= offset <= 2046
    imm11 = (offset >> 1) & 0x7FF
    return struct.pack('<H', 0xE000 | imm11)


def encode_thumb_cbz(rn, from_addr, to_addr):
    offset = to_addr - (from_addr + 4)
    assert 0 <= offset <= 126 and offset % 2 == 0
    i = (offset >> 6) & 1
    imm5 = (offset >> 1) & 0x1F
    return struct.pack('<H', 0xB100 | (i << 9) | (imm5 << 3) | (rn & 7))


def encode_thumb2_ldrb_w(rt, rn, imm12):
    assert 0 <= imm12 < 4096
    return struct.pack('<HH', 0xF890 | (rn & 0xF), (rt << 12) | imm12)


def encode_thumb2_mov_w_imm(rd, imm):
    if imm == 0x100:
        return struct.pack('<HH', 0xF44F, (0x7080 & 0xF0FF) | ((rd & 0xF) << 8))
    elif imm == 0xFFFFFFFF:
        return struct.pack('<HH', 0xF04F, (0x30FF & 0xF0FF) | ((rd & 0xF) << 8))
    raise ValueError(f"Unsupported immediate: {imm:#x}")


def encode_thumb2_bl(from_addr, to_addr):
    offset = to_addr - (from_addr + 4)
    S = 1 if offset < 0 else 0
    abs_offset = offset if offset >= 0 else offset + (1 << 25)
    imm11 = (abs_offset >> 1) & 0x7FF
    imm10 = (abs_offset >> 12) & 0x3FF
    I1 = (abs_offset >> 23) & 1
    I2 = (abs_offset >> 22) & 1
    J1 = (~(I1 ^ S)) & 1
    J2 = (~(I2 ^ S)) & 1
    return struct.pack('<HH', 0xF000 | (S << 10) | imm10, 0xD000 | (J1 << 13) | (J2 << 11) | imm11)


def encode_thumb2_blx(from_addr, to_addr):
    aligned_pc = (from_addr + 4) & ~3
    offset = to_addr - aligned_pc
    S = 1 if offset < 0 else 0
    abs_offset = offset if offset >= 0 else offset + (1 << 25)
    imm10L = (abs_offset >> 2) & 0x3FF
    imm10H = (abs_offset >> 12) & 0x3FF
    I1 = (abs_offset >> 23) & 1
    I2 = (abs_offset >> 22) & 1
    J1 = (~(I1 ^ S)) & 1
    J2 = (~(I2 ^ S)) & 1
    return struct.pack('<HH', 0xF000 | (S << 10) | imm10H, 0xC000 | (J1 << 13) | (J2 << 11) | (imm10L << 1))


def encode_thumb_ldr_pc(rt, from_addr, pool_addr):
    aligned_pc = (from_addr + 4) & ~3
    offset = pool_addr - aligned_pc
    assert 0 <= offset < 1024 and offset % 4 == 0
    return struct.pack('<H', 0x4800 | ((rt & 7) << 8) | ((offset >> 2) & 0xFF))


def patch(input_path, output_path):
    with open(input_path, 'rb') as f:
        data = bytearray(f.read())

    # ── Patch 1: hdmi_encodings "dtshd;" string ──

    str_off = va_to_file(0x47413)
    expected_str = b"[%s:%d] atmos = %d, keys: [%s]"
    assert bytes(data[str_off:str_off+len(expected_str)]) == expected_str, \
        "String mismatch at VA 0x47413 — wrong binary?"

    new_str = b"dtshd;\x00"
    data[str_off:str_off+len(expected_str)+1] = new_str + b'\x00' * (len(expected_str) + 1 - len(new_str))

    # ── Patch 1b: hdmi_encodings code (34 bytes at VA 0x9ab9a) ──

    code_off = va_to_file(0x9ab9a)
    assert bytes(data[code_off:code_off+4]) == bytes.fromhex('95f8c400'), \
        "Code mismatch at VA 0x9ab9a — wrong binary?"

    p = bytearray()
    p += encode_thumb2_ldrb_w(rt=0, rn=5, imm12=0x74)   # ldrb.w r0, [r5, #0x74]
    p += encode_thumb_cbz(rn=0, from_addr=0x9ab9e, to_addr=0x9abba)  # cbz r0, skip
    p += struct.pack('<H', 0x4620)                        # mov r0, r4
    p += encode_thumb2_mov_w_imm(rd=1, imm=0x100)        # mov.w r1, #0x100
    p += encode_thumb2_blx(from_addr=0x9aba6, to_addr=0x13a990)  # blx __strlen_chk
    p += struct.pack('<H', 0x4420)                        # add r0, r4
    p += encode_thumb2_mov_w_imm(rd=1, imm=0xFFFFFFFF)   # mov.w r1, #-1
    p += encode_thumb_ldr_pc(rt=2, from_addr=0x9abb0, pool_addr=0x9acc4)  # ldr r2, [pool]
    p += struct.pack('<H', 0x447A)                        # add r2, pc
    p += encode_thumb2_bl(from_addr=0x9abb4, to_addr=0x9c684)  # bl snprintf
    p += encode_thumb_b(from_addr=0x9abb8, to_addr=0x9a9c8)    # b return
    p += encode_thumb_b(from_addr=0x9abba, to_addr=0x9a9c8)    # b return (skip target)
    assert len(p) == 34
    data[code_off:code_off+34] = p

    # ── Patch 2: NOP the CBZ that gates AUDIO_FORMAT_DTS_HD in sup_formats ──

    nop_off = va_to_file(0xa6f22)
    assert bytes(data[nop_off:nop_off+2]) == bytes.fromhex('50b1'), \
        "CBZ mismatch at VA 0xa6f22 — wrong binary?"
    data[nop_off:nop_off+2] = bytes.fromhex('00bf')  # NOP

    with open(output_path, 'wb') as f:
        f.write(data)
    os.chmod(output_path, 0o644)

    h = hashlib.sha256(data).hexdigest()
    print(f"Patched {output_path}")
    print(f"  sha256: {h}")
    return h


if __name__ == '__main__':
    base = os.path.dirname(os.path.abspath(__file__))
    input_path = os.path.join(base, 'module', 'hal', 'audio.primary.amlogic.so')
    output_path = os.path.join(base, 'module', 'hal', 'audio.primary.amlogic.patched.so')

    if not os.path.exists(input_path):
        input_path = os.path.expanduser('~/Projects/onn audio hal module/pulled/audio.primary.amlogic.so')
        output_path = os.path.expanduser('~/Projects/onn audio hal module/pulled/audio.primary.amlogic.patched.so')

    patch(input_path, output_path)
