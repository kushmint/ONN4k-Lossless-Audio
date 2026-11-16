#!/system/bin/sh
MODDIR=${0%/*}

until [ "$(getprop sys.boot_completed)" = 1 ]; do
	sleep 2
done
sleep 15

. "$MODDIR/common/compat.sh"
. "$MODDIR/common/apply.sh"
