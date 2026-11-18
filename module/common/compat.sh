# Shared bits for customize.sh, service.sh, action.sh and apply.sh.
#
# The patched HAL binary and t9015rate.ko are built for one exact firmware.

SUPPORTED_BUILDS="
jarvis2|5.15.196-android14-11-g3d26c188ef7e-ab14657224|a8d99a85c38e78a7850ae25aa0f29b5f8545d1cf7011f5d73e496b9e1e0e324a
jarvis2|5.15.196-android14-11-g3d26c188ef7e-ab14657224|98a914e0fa1b3755d4caf1db1912f5e7f4eb1e9923f5891786b503c6e3941c43
"

# Audio HAL builds we have patched. The CA and US boxes ship different HAL builds, so the patched
# HAL must match the stock one exactly (otherwise we would mount the wrong build).
HAL_STOCK_CA=139a5fd567cddfb726669d0d4296817ebed4b17495c5af18e04064d184cb58e0
HAL_STOCK_US=bc26b0cda948f2021b35c7c2f95ced32809babc9bedc30a8e817deee2e91b228
HAL_PATCHED_CA=2aaf74134edcf544c396540c1ae6a2b554a97a1c3c09f633ea5b02745ce82638
HAL_PATCHED_US=5a9b8238a36f332eaa11a43130a210b7b26f68b388c5fc590f29c90bf8032b79
# earlier v2.0/v2.1-dev patched builds (patch 3 variants), still recognised if one is mounted
HAL_OLD_CA=f56c5262a1efb5c2d1c70e9380958a24058e3580cdbd2e27284895969dc84a14
HAL_OLD_US=1e11233be59f7cc91693dddb0c7a9898c9a017c71316cf61679a2454e09cc409

T9015_KO=/vendor/lib/modules/amlogic-snd-codec-t9015.ko
AUDIO_HAL=/vendor/lib/hw/audio.primary.amlogic.so
POLICY=/odm/etc/audio_policy_configuration.xml
AML_CONFIG=/vendor/etc/aml_audio_config.json

TRUEHD_PROP=ro.vendor.platform.is.aml_truehd_passthrough
FORCEDDP_PROP=ro.vendor.platform.is.forceddp

AML_CONFIG_STOCK_SHA256=f960a9910e66cf3ff63ba8794c3ffa7b7e7c469d0cff356c9a6b83eb03daeafe

TVSETTINGS_APK=/system_ext/priv-app/TvSettingsTwoPanel/TvSettingsTwoPanel.apk
TVSETTINGS_SHA256=d633d85309b584a60a8c8335b197a75c2a71447675eff9559b61afaf11d163ce
OVERLAY_PKG=com.onn.truehd.settingsoverlay
SOUND_ACTIVITY=com.droidlogic.tv.settings/.SoundActivity

COMPAT_REASON=""

BB=/data/adb/magisk/busybox

# DroidAudio service: call 21 = setDigitalAudioMode, call 22 = getDigitalAudioMode
# Modes: 0 PCM, 1 Auto, 2 Manual, 3 Passthrough, 4 Always
DROIDAUDIO=vendor.amlogic.hardware.droidaudio.IDroidAudio/default

t9015_data_base() {
	local old base
	old=$(cat /proc/sys/kernel/kptr_restrict)
	echo 0 > /proc/sys/kernel/kptr_restrict
	base=$(cat /sys/module/amlogic_snd_codec_t9015/sections/.data)
	echo "$old" > /proc/sys/kernel/kptr_restrict
	echo "$base"
}

digital_mode_get() {
	/system/bin/service call "$DROIDAUDIO" 22 2>/dev/null |
		sed -n "s/.*Parcel(.*00000000 \([0-9a-f]\{8\}\) .*/\1/p" |
		{ read -r hex && [ -n "$hex" ] && echo $((0x$hex)); }
}

digital_mode_set() {
	/system/bin/service call "$DROIDAUDIO" 21 i32 "$1" s16 "" >/dev/null 2>&1 &&
		[ "$(digital_mode_get)" = "$1" ]
}

hal_mode() {
	/system/bin/dumpsys media.audio_flinger 2>/dev/null |
		sed -n 's/.*digital_audio_mode *: *\([A-Z_]*\).*/\1/p' | head -n 1
}

mode_name() {
	case "$1" in
	0) echo PCM ;; 1) echo Automatic ;; 2) echo Manual ;;
	3) echo Passthrough ;; 4) echo Always ;; *) echo unknown ;;
	esac
}

surround_has_truehd() {
	awk '/<surroundSound>/ { s = 1 } s && /AUDIO_FORMAT_DOLBY_TRUEHD/ { f = 1 }
	     /<\/surroundSound>/ { s = 0 } END { exit !f }' "$1"
}

surround_has_dtshd() {
	awk '/<surroundSound>/ { s = 1 } s && /AUDIO_FORMAT_DTS_HD/ { f = 1 }
	     /<\/surroundSound>/ { s = 0 } END { exit !f }' "$1"
}

settings_overlay_compatible() {
	[ "$(sha256sum "$TVSETTINGS_APK" 2>/dev/null | cut -d' ' -f1)" = "$TVSETTINGS_SHA256" ]
}

# Prints ca or us for a known audio HAL build (stock or already patched), nothing otherwise.
hal_variant() {
	case "$(sha256sum "$AUDIO_HAL" 2>/dev/null | cut -d' ' -f1)" in
	"$HAL_STOCK_CA" | "$HAL_PATCHED_CA" | "$HAL_OLD_CA") echo ca ;;
	"$HAL_STOCK_US" | "$HAL_PATCHED_US" | "$HAL_OLD_US") echo us ;;
	esac
}

compat_check() {
	local device kernel ko_sum line
	device=$(getprop ro.product.device)
	kernel=$(uname -r)

	[ -f "$T9015_KO" ] || { COMPAT_REASON="T9015 codec driver not found"; return 1; }
	ko_sum=$(sha256sum "$T9015_KO" | cut -d' ' -f1)

	for line in $SUPPORTED_BUILDS; do
		if [ "$line" = "$device|$kernel|$ko_sum" ]; then
			[ -f "$AUDIO_HAL" ] || { COMPAT_REASON="audio HAL not found"; return 1; }
			[ -n "$(hal_variant)" ] || { COMPAT_REASON="audio HAL is not a build this module has patched"; return 1; }
			$BB grep -q "$TRUEHD_PROP" "$AUDIO_HAL" 2>/dev/null || {
				COMPAT_REASON="audio HAL has no TrueHD passthrough switch"
				return 1
			}
			grep -q '<surroundSound>' "$POLICY" 2>/dev/null || {
				COMPAT_REASON="audio policy has no surround format list"
				return 1
			}
			if ! grep -q Passthrough_Audio_Config "$AML_CONFIG" &&
			   [ "$(sha256sum "$AML_CONFIG" | cut -d' ' -f1)" != "$AML_CONFIG_STOCK_SHA256" ]; then
				COMPAT_REASON="audio HAL config is not the stock file"
				return 1
			fi
			return 0
		fi
	done
	COMPAT_REASON="unsupported build (device=$device kernel=$kernel)"
	return 1
}

compat_runtime() {
	[ -r /sys/module/amlogic_snd_codec_t9015/sections/.data ] || {
		COMPAT_REASON="T9015 codec driver is not loaded"
		return 1
	}
	grep -q AMLAUGESOUND /proc/asound/cards 2>/dev/null || {
		COMPAT_REASON="Amlogic sound card is not registered"
		return 1
	}
	[ -n "$(digital_mode_get)" ] || {
		COMPAT_REASON="vendor audio service is not answering"
		return 1
	}
	return 0
}
