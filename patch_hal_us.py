#!/usr/bin/env python3
"""Patch the US-firmware audio.primary.amlogic.so (stock sha256 bc26b0cd...) with patches 1-2 from
patch_hal.py. The US HAL is a different build: text is shifted -8 bytes vs the Canadian HAL
(139a5fd5...), rodata is identical. Patches 3 and 4 are NOT applied (module uses real Passthrough mode; 4 deadlocks).

usage: patch_hal_us.py <stock-US-HAL> <output>
All patch sites are verified against expected original bytes before writing."""
import sys, struct, hashlib, importlib.util, os
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ph", os.path.join(here, "patch_hal.py"))
ph = importlib.util.module_from_spec(spec); spec.loader.exec_module(ph)

US_STOCK_SHA256 = "bc26b0cda948f2021b35c7c2f95ced32809babc9bedc30a8e817deee2e91b228"
SHIFT = 8  # US text addresses are this much lower than Canadian ones (in the patched regions)

def patch(src, dst):
    data = bytearray(open(src, "rb").read())
    h = hashlib.sha256(data).hexdigest()
    assert h == US_STOCK_SHA256, "not the stock US HAL (sha256 %s)" % h
    va = ph.va_to_file

    # Patch 1a: log format string -> "dtshd;" (same file offset as Canadian: rodata unchanged)
    s_off = va(0x47413); exp = b"[%s:%d] atmos = %d, keys: [%s]"
    assert data[s_off:s_off+len(exp)] == exp, "string mismatch"
    new = b"dtshd;\x00"
    data[s_off:s_off+len(exp)+1] = new + b"\x00" * (len(exp) + 1 - len(new))

    # Patch 1b: hdmi_encodings code block (Ghidra VA = IDA VA + 0x10000)
    B = 0x9ab9a - SHIFT                       # block start
    off = va(B)
    assert data[off:off+4] == bytes.fromhex("95f8c400"), "1b head mismatch"
    assert data[off+4:off+8] == bytes.fromhex("41f29721"), "1b second insn mismatch"
    STRLEN_CHK = 0x13a990 - 0x10               # __strlen_chk PLT, IDA 0x12a980
    SNPRINTF   = 0x9c684 - SHIFT               # sub_8C67C
    RET        = 0x9a9c8 - SHIFT               # loc_8A9C0
    # literal pool word of the original LDR R2,=aSDAtmosDKeysS: decode from the original LDR at IDA 0x8aba4
    ldr_va = 0x9abac - SHIFT                   # Ghidra VA of that LDR R2,[pc,#imm]
    hw = struct.unpack("<H", data[va(ldr_va):va(ldr_va)+2])[0]
    assert hw & 0xF800 == 0x4800 and (hw >> 8) & 7 == 2, "original LDR R2 literal not found (%#06x)" % hw
    pool = ((ldr_va + 4) & ~3) + (hw & 0xFF) * 4
    pool_val = struct.unpack("<i", data[va(pool):va(pool)+4])[0]
    add_pc = B + 0x18                          # where our ADD R2,PC lands (same slot as the original)
    p = bytearray()
    p += ph.encode_thumb2_ldrb_w(rt=0, rn=5, imm12=0x74)
    p += ph.encode_thumb_cbz(rn=0, from_addr=B + 4, to_addr=B + 0x20)
    p += struct.pack("<H", 0x4620)
    p += ph.encode_thumb2_mov_w_imm(rd=1, imm=0x100)
    p += ph.encode_thumb2_blx(from_addr=B + 0xc, to_addr=STRLEN_CHK)
    p += struct.pack("<H", 0x4420)
    p += ph.encode_thumb2_mov_w_imm(rd=1, imm=0xFFFFFFFF)
    p += ph.encode_thumb_ldr_pc(rt=2, from_addr=B + 0x16, pool_addr=pool)
    p += struct.pack("<H", 0x447A)
    p += ph.encode_thumb2_bl(from_addr=B + 0x1a, to_addr=SNPRINTF)
    p += ph.encode_thumb_b(from_addr=B + 0x1e, to_addr=RET)
    p += ph.encode_thumb_b(from_addr=B + 0x20, to_addr=RET)
    assert len(p) == 34
    # the pool word must resolve to the "dtshd;" string at VA 0x47413 when ADD R2,PC runs at B+0x18
    expect_pool = (0x47413 - (B + 0x18 + 4)) & 0xFFFFFFFF
    assert (pool_val & 0xFFFFFFFF) == expect_pool, "pool %#x != expected %#x" % (pool_val & 0xFFFFFFFF, expect_pool)
    data[off:off+34] = p

    # Patch 2: NOP the CBZ gating DTS_HD in sup_formats
    o2 = va(0xa6f22 - SHIFT); assert data[o2:o2+2] == bytes.fromhex("50b1"), "patch 2 mismatch"
    data[o2:o2+2] = bytes.fromhex("00bf")

    open(dst, "wb").write(data); os.chmod(dst, 0o644)
    print("patched ->", dst, hashlib.sha256(data).hexdigest())

if __name__ == "__main__":
    patch(sys.argv[1], sys.argv[2])
