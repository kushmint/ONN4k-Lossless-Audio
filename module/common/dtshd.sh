# DTS-HD MA lossless over HDMI HBR. Sourced by apply.sh.
#
# Two pieces, applied together or not at all:
#   1. libamladecs.so (the Amlogic decoder wrapper): copy the device's own file, verify every
#      original byte, patch 3 spots, mount the copy. file offset = VA - 0x10000
#        0x6490  MOV.W R0,#0xB000000 -> #0xC000000   raw inner format DTS -> DTS_HD
#        0x64b6  MOVS  R1,#2        -> #8            raw channels 8 -> HAL picks the HBR device
#        0x64be  IT NE; MOVWNE R3,#0xBB80 -> NOPs    stop clamping the raw sample rate to 48 kHz
#   2. libHwAudio_dtshd.so replacement: builds IEC61937-5 type IV (DTS-HD) HBR bursts.
#      Source: src/dtshd/dtshd_passthrough.c
# If the wrapper's bytes are not exactly what we expect (other firmware), nothing is changed and
# DTS Core passthrough keeps working with the stock libraries.

AMLADECS=/vendor/lib/libamladecs.so
DTS_LIB=/odm/lib/libHwAudio_dtshd.so
GEN_AMLADECS=$STATE/libamladecs.so
GEN_DTS_LIB=$STATE/libHwAudio_dtshd.so

# hex string -> raw bytes on stdout
hex2bin() {
	local h="$1"
	while [ -n "$h" ]; do
		printf "\\$(printf '%03o' "0x${h%"${h#??}"}")"
		h="${h#??}"
	done
}

# bytes_at FILE OFFSET COUNT -> hex string
bytes_at() {
	$BB dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | $BB od -An -tx1 | $BB tr -d ' \n'
}

# patch_at FILE OFFSET OLDHEX NEWHEX -> 0 if applied, 1 if original bytes did not match
patch_at() {
	local f="$1" off="$2" old="$3" new="$4"
	[ "$(bytes_at "$f" "$off" $((${#old} / 2)))" = "$old" ] || return 1
	hex2bin "$new" | $BB dd of="$f" bs=1 seek="$off" conv=notrunc 2>/dev/null
	[ "$(bytes_at "$f" "$off" $((${#new} / 2)))" = "$new" ]
}

# Returns 0 and sets DTSHD_MOUNTED=1 when both pieces are mounted. Never fatal.
apply_dtshd() {
	DTSHD_MOUNTED=0
	local lib="$MODDIR/hal/libHwAudio_dtshd.so"
	[ -f "$lib" ] || { log "DTS-HD: replacement decoder not in module, skipping"; return 1; }
	[ -f "$AMLADECS" ] && [ -f "$DTS_LIB" ] || { log "DTS-HD: wrapper or decoder lib not found, skipping"; return 1; }
	if mounted "$AMLADECS" || mounted "$DTS_LIB"; then
		log "DTS-HD: already mounted"; DTSHD_MOUNTED=1; return 0
	fi

	cp "$AMLADECS" "$GEN_AMLADECS" || { log "DTS-HD: could not copy wrapper"; return 1; }
	if ! patch_at "$GEN_AMLADECS" $((0x6490)) 4ff03060 4ff04060 ||
	   ! patch_at "$GEN_AMLADECS" $((0x64b6)) 0221 0821 ||
	   ! patch_at "$GEN_AMLADECS" $((0x64be)) 18bf4bf68033 00bf00bf00bf; then
		log "DTS-HD: libamladecs.so is not the expected build, skipping (DTS Core still works)"
		rm -f "$GEN_AMLADECS"
		return 1
	fi
	cp "$lib" "$GEN_DTS_LIB"
	chmod 0644 "$GEN_AMLADECS" "$GEN_DTS_LIB"
	chcon u:object_r:vendor_file:s0 "$GEN_AMLADECS" "$GEN_DTS_LIB"

	if ! bind "$GEN_AMLADECS" "$AMLADECS"; then
		log "DTS-HD: could not mount patched wrapper"; return 1
	fi
	if ! bind "$GEN_DTS_LIB" "$DTS_LIB"; then
		log "DTS-HD: could not mount decoder lib, undoing wrapper mount"
		unbind "$AMLADECS"; return 1
	fi
	DTSHD_MOUNTED=1
	log "DTS-HD: patched wrapper + HBR decoder mounted"
}
