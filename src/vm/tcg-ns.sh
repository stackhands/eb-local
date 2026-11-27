#!/bin/bash
# First stage of `eb-local __vm-run --mode tcg` when the host has no
# binfmt_misc entry for the emulator: runs in a user and mount namespace of
# its own, registers the emulator there, then runs the job under the caller's
# own uid in a nested user namespace. Needs EBVM_ARCH, EBVM_QEMU_USER,
# EBVM_QEMU_CPU, EBVM_UID, EBVM_GID, EBVM_JOB and EBVM_PATH.
set -u
mount -t binfmt_misc none /proc/sys/fs/binfmt_misc || { echo "eb-local: vm-run: cannot mount binfmt_misc in a user namespace" >&2; exit 125; }
case $EBVM_ARCH in
  aarch64) entry=':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:' ;;
  x86_64) entry=':qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:' ;;
esac
printf '%s\n' "${entry}${EBVM_QEMU_USER}:OCF" > /proc/sys/fs/binfmt_misc/register || { echo "eb-local: vm-run: cannot register $EBVM_QEMU_USER" >&2; exit 125; }
exec unshare -U --map-user="$EBVM_UID" --map-group="$EBVM_GID" env QEMU_CPU="$EBVM_QEMU_CPU" PATH="$EBVM_PATH" bash "$EBVM_JOB"
