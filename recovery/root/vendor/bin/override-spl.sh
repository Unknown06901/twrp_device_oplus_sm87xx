#!/sbin/sh
#
# Give KeyMint the same OS version and security patch levels that the
# installed ROM gives it in Android. KeyMint (libqtikeymint) binds every key
# to ro.build.version.release, ro.build.version.security_patch and
# ro.vendor.build.security_patch: older values make the keys look rolled back,
# newer ones make it ask to upgrade (rewrite) them, and decryption fails.
#
# The values are resolved from the installed slot's partitions the same way
# Android's init does (system/core/init/property_service.cpp): fixed partition
# order, later files override earlier ones, `import` lines followed with
# ${prop} expansion, and /vendor* /odm* files may not set ro.build.* (vendor
# context). This makes it independent of the ROM, e.g. OPLUS ROMs override the
# vendor patch level from /mnt/vendor/my_manifest/build.prop via odm.
#
# KeyMint is started only once all three values are known and this
# recovery's header carries the installed ROM's boot patch level, so it never
# runs with values that would make it rewrite the user's keys.
#
# SPL_DRY_RUN=1 only prints the result (no resetprop, KeyMint not started).

SCRIPTNAME="override-spl.sh"
MNT=/tmp/spl_mnt
KEYMINT_PROPS="ro.build.version.release ro.build.version.security_patch ro.vendor.build.security_patch"

log() {
	echo "I:$SCRIPTNAME: $1" | tee -a /dev/kmsg
	echo "I:$SCRIPTNAME: $1" | tee -a /tmp/recovery.log
}

if [ "$(getprop ro.twrp.fastbootd)" = "1" ]; then
	log "Detected fastbootd (ro.twrp.fastbootd=1), exit script."
	exit 0
fi

SLOT=$(getprop ro.boot.slot_suffix)
if [ -z "$SLOT" ]; then
	log "No slot detected, KeyMint not started."
	setprop crypto.ready 1
	exit 1
fi
log "Slot detected: $SLOT"

if [ "$SPL_DRY_RUN" != "1" ]; then
	umount -f -l /system 2>/dev/null
	umount -f -l /system_root 2>/dev/null
	umount -f -l /vendor 2>/dev/null
fi

# Print the directory where logical partition $1 of this slot is mounted
# read-only, mounting it on first use. Fails if the partition does not exist.
part_dir() {
	local dir="$MNT/$1" blk="/dev/block/mapper/$1$SLOT"
	if ! grep -q " $dir " /proc/mounts; then
		[ -e "$blk" ] || return 1
		mkdir -p "$dir"
		if ! mount -o ro "$blk" "$dir" 2>/dev/null; then
			rmdir "$dir" 2>/dev/null
			return 1
		fi
	fi
	echo "$dir"
}

# Map an Android path (/odm/etc/build.prop, /mnt/vendor/my_manifest/...) to
# the file inside the mounted partition.
host_path() {
	local p="$1" part rest dir
	case "$p" in
	/mnt/vendor/*) p="${p#/mnt/vendor}" ;;
	esac
	part="${p#/}"
	part="${part%%/*}"
	rest="${p#/$part}"
	dir=$(part_dir "$part") || return 1
	# system images are system-as-root: /system/... lives under system/
	if [ "$part" = "system" ]; then
		echo "$dir/system$rest"
	else
		echo "$dir$rest"
	fi
}

# Expand ${prop} and ${prop:-default} like init's ExpandProps; fails when a
# property is unset and has no default (init then skips the import).
expand_props() {
	local s="$1" name val
	while :; do
		name=$(echo "$s" | sed -n 's/^[^$]*\${\([^}]*\)}.*/\1/p')
		[ -n "$name" ] || break
		val=$(getprop "${name%%:-*}")
		if [ -z "$val" ]; then
			case "$name" in
			*:-*) val="${name#*:-}" ;;
			*) return 1 ;;
			esac
		fi
		s=$(echo "$s" | sed "s|\${$name}|$val|")
	done
	echo "$s"
}

# Print "key=value" for each KEYMINT_PROPS assignment in Android file $1,
# following imports, in load order. $2 is an import filter ("ro.foo.*" or an
# exact key); filtered loads ignore nested imports, as in init.
load_file() {
	local path="$1" filter="$2" file vendorctx=0 line key imp
	file=$(host_path "$path") || return 0
	[ -f "$file" ] || return 0
	case "$path" in
	/vendor*|/odm*) vendorctx=1 ;;
	esac
	grep -E '^[[:space:]]*(import[[:space:]]|ro\.(build\.version\.(release|security_patch)|vendor\.build\.security_patch)[[:space:]]*=)' "$file" |
	sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
	while IFS= read -r line; do
		case "$line" in
		import*)
			[ -n "$filter" ] && continue
			set -- $line
			imp=$(expand_props "$2") || continue
			load_file "$imp" "$3"
			;;
		*)
			line=$(echo "$line" | sed 's/[[:space:]]*=[[:space:]]*/=/')
			key="${line%%=*}"
			case "$filter" in
			"") ;;
			*\*) case "$key" in "${filter%\*}"*) ;; *) continue ;; esac ;;
			*) [ "$key" = "$filter" ] || continue ;;
			esac
			if [ "$vendorctx" = "1" ]; then
				case "$key" in ro.build.*) continue ;; esac
			fi
			echo "$line"
			;;
		esac
	done
}

# /<part>/etc/build.prop, or the legacy /<part>/default.prop + build.prop.
load_partition() {
	local f
	if f=$(host_path "/$1/etc/build.prop") && [ -f "$f" ]; then
		load_file "/$1/etc/build.prop"
	else
		load_file "/$1/default.prop"
		load_file "/$1/build.prop"
	fi
}

resolve_props() {
	load_file /system/build.prop
	load_partition system_ext
	load_file /system_dlkm/etc/build.prop
	load_file /vendor/default.prop
	load_file /vendor/build.prop
	load_file /vendor_dlkm/etc/build.prop
	load_file /odm_dlkm/etc/build.prop
	load_partition odm
	load_partition product
}

# os_version field (version and patch level) of the boot image header in
# partition $1 of this slot, as 8 hex digits.
hdr_os_version() {
	local blk="/dev/block/bootdevice/by-name/$1$SLOT"
	[ -e "$blk" ] || return 1
	[ "$(dd if="$blk" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || return 1
	dd if="$blk" bs=4 skip=4 count=1 2>/dev/null | od -An -tx4 | tr -d ' \n'
}

# Halves keep the arithmetic within signed 32 bits (mksh).
decode_os_version() {
	local hi=$((0x$(echo "$1" | cut -c1-4))) lo=$((0x$(echo "$1" | cut -c5-8))) ver p
	ver=$(((hi << 5) | (lo >> 11)))
	p=$((lo & 2047))
	echo "$((ver >> 14)).$(((ver >> 7) & 127)).$((ver & 127)) / $((2000 + (p >> 4)))-$((p & 15))"
}

mkdir -p "$MNT"
RESOLVED=$(resolve_props)
for d in "$MNT"/*; do
	[ -d "$d" ] || continue
	umount -f -l "$d" 2>/dev/null
	rmdir "$d" 2>/dev/null
done
rmdir "$MNT" 2>/dev/null

MISSING=0
for PROP in $KEYMINT_PROPS; do
	VAL=$(echo "$RESOLVED" | grep "^$PROP=" | tail -n 1 | cut -d'=' -f2-)
	if [ -z "$VAL" ]; then
		log "Unable to resolve $PROP from the installed ROM"
		MISSING=1
	elif [ "$SPL_DRY_RUN" = "1" ]; then
		echo "$PROP=$VAL"
	else
		resetprop "$PROP" "$VAL"
		log "Override $PROP to $VAL"
	fi
done

# The bootloader gives KeyMint the boot patch level from the header of the
# image it booted; in Android that is init_boot (boot when init_boot carries
# none), here it is this recovery. If they differ, KeyMint would ask to
# upgrade the keys to this recovery's level, so do not start it.
BOOT_OSV=$(hdr_os_version init_boot)
case "$BOOT_OSV" in
""|00000000) BOOT_OSV=$(hdr_os_version boot) ;;
esac
OWN_OSV=$(hdr_os_version recovery)
case "$BOOT_OSV" in
""|00000000)
	log "No boot patch level in init_boot/boot header, not compared"
	;;
"$OWN_OSV")
	log "Boot patch level matches installed ROM: $(decode_os_version "$BOOT_OSV")"
	;;
*)
	log "Boot patch level mismatch: installed ROM $(decode_os_version "$BOOT_OSV") (0x$BOOT_OSV), this recovery $(decode_os_version "${OWN_OSV:-0}") (0x$OWN_OSV)"
	log "Re-stamp this recovery's header os_version to 0x$BOOT_OSV to decrypt"
	MISSING=1
	;;
esac
[ "$SPL_DRY_RUN" = "1" ] && exit "$MISSING"

setprop crypto.ready 1
log "crypto.ready 1"

if [ "$MISSING" = "1" ]; then
	log "KeyMint not started: it must not run with placeholder values."
	exit 1
fi

start vendor.keymint-qti
log "started vendor.keymint-qti"

exit 0
