#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common/compat.sh"

yes_no() { if "$@"; then echo yes; else echo no; fi; }

/system/bin/am start -n "$SOUND_ACTIVITY" >/dev/null 2>&1 &&
	echo "Opened onn's sound menu on the TV." && echo

echo "onn 4K Pro Lossless Audio Passthrough"
echo
if compat_check; then echo "Firmware:          supported"; else echo "Firmware:          $COMPAT_REASON"; fi
echo "192 kHz helper:    $(yes_no grep -q '^t9015rate ' /proc/modules)"
echo "TrueHD switch:     $(getprop $TRUEHD_PROP)"
echo "Force DD+:         $(getprop $FORCEDDP_PROP)"
echo "TrueHD in formats: $(yes_no surround_has_truehd $POLICY)"
echo "DTS-HD in formats: $(yes_no surround_has_dtshd $POLICY)"
echo "Hidden options:    $(yes_no grep -q Passthrough_Audio_Config $AML_CONFIG)"
echo "Settings row:      $(/system/bin/cmd overlay list "$OVERLAY_PKG" 2>/dev/null | grep -q '\[x\]' && echo yes || echo no)"
echo "Audio output mode: $(mode_name "$(digital_mode_get)") (HAL: $(hal_mode))"
echo "DTS-HD profile:    $(/system/bin/dumpsys media.audio_policy 2>/dev/null | grep -q 'AUDIO_FORMAT_DTS_HD' && echo yes || echo no)"
echo
echo "Last log lines:"
tail -n 8 /data/adb/onn_lossless/apply.log 2>/dev/null
