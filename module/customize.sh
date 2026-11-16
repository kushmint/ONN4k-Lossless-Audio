. "$MODPATH/common/compat.sh"

ui_print "- onn 4K Pro Lossless Audio Passthrough"
ui_print "- TrueHD/Atmos + DTS-HD MA/DTS:X"
ui_print "- Checking device and firmware"

if ! compat_check; then
	ui_print "! $COMPAT_REASON"
	abort "! Not installed: this build is not supported. Nothing was changed."
fi

ui_print "- Supported: $(getprop ro.product.device), kernel $(uname -r)"
ui_print "- Nothing is written to system partitions. Changes are made"
ui_print "  in memory after each boot."
ui_print "- After the reboot, lossless passthrough is enabled"
ui_print "  automatically. Use the standard surround sound settings"
ui_print "  (Auto / Manual / None) as normal."
ui_print "- To turn it off: disable or remove it in Magisk and reboot."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
