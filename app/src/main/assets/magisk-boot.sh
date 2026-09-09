#!/system/bin/sh
#
# Rewritten for modern Magisk (v25+, tested against source v30.7)
# Original by diplomatic, adapted by JunioJsv (targeted Magisk v20.4)
#
# ARCHITECTURE NOTE (why this differs completely from the original):
# Magisk v20.4's magiskinit was a multi-call binary (magisk/magiskinit/
# magiskpolicy all symlinked to one ELF, dispatched by argv0) that could
# be manually driven post-boot via -c/--post-fs-data/--service/--boot-complete.
# Since ~v25, magiskinit ONLY runs when getpid()==1 (real init, PID 1) -
# confirmed in native/src/init/init.rs upstream source. It refuses to do
# anything in a late root-shell context like this one.
#
# The daemon lifecycle commands (--daemon/--post-fs-data/--service/
# --boot-complete) still exist, but moved to a SEPARATE binary: `magisk`
# (libmagisk.so per-ABI in the official APK), not magiskinit.
#
# get_magisk_tmp() (native/src/core/utils.cpp) resolves MAGISKTMP by
# probing for a ".magisk" marker dir under /debug_ramdisk or /sbin -
# it does NOT read an env var as primary source. So we recreate that
# marker manually before invoking the daemon.
#
# UNTESTED ON REAL HARDWARE - no MTK device with pre-March/2020 patch
# level was available to validate this end-to-end. Validated only by
# reading Magisk's current source (init.rs, daemon.rs, utils.cpp,
# consts.hpp, magisk.rs, sepolicy/cli.rs). Please report the exact
# failing step if this breaks.
#
# WARNING: DO NOT UPDATE MAGISK THROUGH MAGISK MANAGER OR YOU WILL BRICK
#          YOUR DEVICE ON A LOCKED BOOTLOADER

HOMEDIR="$(dirname $0)/$1"
INTLROOT=".magisk"

SU_MINISCRIPT='
# Magisk function to find boot partition and prevent the installer from finding
# it again (kept from original - unrelated to the daemon bootstrap rewrite)
find_block() {
  for BLOCK in "$@"; do
    DEVICES=$(find /dev/block -type l -iname $BLOCK) 2>/dev/null
    for DEVICE in $DEVICES; do
      cd ${DEVICE%/*}
      local BASENAME="${DEVICE##*/}"
      mv "$BASENAME" ".$BASENAME"
      cd -
    done
  done
  typeset -l PARTNAME BLOCK
  local FILELIST=$(grep -s PARTNAME= /sys/dev/block/*/uevent) 2>/dev/null
  for uevent in $FILELIST; do
    local PARTNAME=${uevent##*PARTNAME=}
    for BLOCK in "$@"; do
      if [ "$BLOCK" = "$PARTNAME" ]; then
        local FNAME=${uevent%:*}
        chmod 0 $FNAME
      fi
    done
  done
  return 0
}

# Root only at this point; hoping selinux is permissive
if [ $(id -u) != 0 ] || [ "$(getenforce)" != "Permissive" ]; then
	echo "Root user only" >&2
	exit 1
fi

# Disaster prevention
SLOT=$(getprop ro.boot.slot_suffix)
find_block boot$SLOT

cd $HOMEDIR || { setenforce 1; exit 1; }

TMPROOT=/sbin
if ! mount | grep -q " $TMPROOT "; then
	mount -t tmpfs -o mode=755 magisk $TMPROOT 2>/dev/null
fi
mkdir -p $TMPROOT/$INTLROOT
chmod 700 $TMPROOT/$INTLROOT
echo "RECOVERYMODE=false" > $TMPROOT/$INTLROOT/config


# NOTE ON NAMING: the app still extracts assets as "magiskinit32/64" and
# "magiskpolicy32/64" (unchanged filenames, to avoid touching more of the
# app than necessary) - after the app's suffix-stripping copy step, the
# local files in this dir are literally named "magiskinit" and
# "magiskpolicy". Their CONTENT is the modern multi-call magisk binary
# and magiskpolicy binary respectively. We rename on copy into $TMPROOT
# because applets.cpp dispatches behavior by basename(argv[0]) - it must
# be invoked as literally "magisk" to behave as the magisk multi-call
# binary (daemon/su/etc), regardless of what it was named on disk here.
cp -f magiskinit $TMPROOT/magisk
cp -f magiskpolicy $TMPROOT/magiskpolicy
chmod 755 $TMPROOT/magisk $TMPROOT/magiskpolicy
chcon u:object_r:magisk_file:s0 $TMPROOT/magisk $TMPROOT/magiskpolicy 2>/dev/null

# Modern Magisk has no standalone "su" binary - su is the same multi-call
# binary invoked as argv0="su" (applets.cpp: {"su", su_client_main}).
# The app's ExploitHandler.kt checks File("/sbin/su").exists() as its
# success marker, so this symlink must exist for the app to report success.
ln -sf magisk $TMPROOT/su
chcon u:object_r:magisk_file:s0 $TMPROOT/su 2>/dev/null

# Live sepolicy patch (same CLI contract as before - confirmed unchanged
# in sepolicy/cli.rs upstream)
$TMPROOT/magiskpolicy --live --magisk "allow magisk * * *"

export MAGISKTMP=$TMPROOT
export PATH=$TMPROOT:$PATH

# Manually drive the daemon lifecycle (equivalent of what magiskinit used
# to trigger automatically during boot). --daemon does not appear to
# double-fork in the source (daemon_entry() sets its own sid/std streams
# but does not fork+exit a parent) - launch it backgrounded and detached.
setsid $TMPROOT/magisk --daemon >/dev/null 2>&1 &
disown
sleep 1

$TMPROOT/magisk --post-fs-data
sleep 1
$TMPROOT/magisk --service
$TMPROOT/magisk --boot-complete

setenforce 1
'

cd $HOMEDIR || exit 1

# strip '\''c512...'\'' tail from selinux context
ctx=$(cat /proc/$$/attr/current)
newctx=${ctx/%:s0:*/:s0}

# start SU daemon
export HOMEDIR
echo "$SU_MINISCRIPT" | "./mtk-su" -v -Z $newctx
