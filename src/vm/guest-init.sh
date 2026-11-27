#!/bin/bash
# PID 1 of an `eb-local __vm-run --mode kvm` guest. The root file system is the
# host's own, read-only over virtiofs; /tmp and /run are tmpfs, and every other
# writable path is a virtiofs share named in the job directory's `mounts` file.
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
# udev would create these; without /dev/fd EESSI's archdetect falls back to generic.
ln -sfn /proc/self/fd /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs shm /dev/shm
mount -t tmpfs tmp /tmp
mount -t tmpfs run /run
mkdir -p /run/ebvm
mount -t virtiofs job /run/ebvm || { echo o > /proc/sysrq-trigger; sleep 30; }
ip link set lo up 2>/dev/null
# ttyS1 and ttyS2 carry the command's stdout and stderr; raw keeps newlines unchanged.
stty -F /dev/ttyS1 raw -echo 2>/dev/null
stty -F /dev/ttyS2 raw -echo 2>/dev/null
while read -r kind a b c; do
  case $kind in
    tmpfs) mount -t tmpfs "$a" "$b" ;;
    virtiofs)
      mkdir -p "$b" 2>/dev/null
      mount -t virtiofs -o "$c" "$a" "$b" || echo "mount of share $a on $b failed" >> /run/ebvm/init.log ;;
  esac
done < /run/ebvm/mounts
. /run/ebvm/ids
if [ -n "$EBVM_GROUPS" ]; then groups="--groups=$EBVM_GROUPS"; else groups=--clear-groups; fi
setpriv --reuid="$EBVM_UID" --regid="$EBVM_GID" "$groups" \
  bash /run/ebvm/job.sh < /dev/null > /dev/ttyS1 2> /dev/ttyS2
echo $? > /run/ebvm/status
sync
echo o > /proc/sysrq-trigger
sleep 30
