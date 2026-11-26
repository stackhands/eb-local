#!/bin/bash
# Runs inside the guest before COMMAND. Exits 1, with the reason in
# $EBVM_DIR/refused, unless every detector names the target:
#   EBVM_ARCH EBVM_TARGET EBVM_VENDOR EBVM_ARCHSPEC EBVM_GCC (alternatives)
#   EBVM_EESSI_VERSION EBVM_ALLOW_ARCHSPEC EBVM_GCC_BIN
set +u
refuse() {
  printf '%s\n' "$*" > "$EBVM_DIR/refused"
  echo "eb-local: vm-run: refused: $*" >&2
  exit 1
}
[ -e /dev/fd/0 ] || refuse "/dev/fd is missing, so EESSI archdetect would fall back to generic"
case $EBVM_ARCH in
  x86_64) vendor=$(sed -n 's/^vendor_id[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1) ;;
  aarch64) vendor=$(sed -n 's/^CPU implementer[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1) ;;
esac
[ "$vendor" = "$EBVM_VENDOR" ] || refuse "the CPU vendor reads '$vendor', $EBVM_TARGET needs '$EBVM_VENDOR'"
unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_SOFTWARE_SUBDIR EESSI_PREFIX EESSI_VERSION_OVERRIDE
init=/cvmfs/software.eessi.io/versions/$EBVM_EESSI_VERSION/init/bash
[ -r "$init" ] || refuse "EESSI $EBVM_EESSI_VERSION is not readable at $init"
source "$init" > /dev/null 2>&1
[ -n "$EESSI_SOFTWARE_SUBDIR" ] || refuse "EESSI $EBVM_EESSI_VERSION did not load"
archdetect=$("$EESSI_PREFIX/init/eessi_archdetect.sh" cpupath 2> /dev/null | head -n 1 | cut -d: -f1)
[ "$archdetect" = "$EBVM_TARGET" ] || refuse "EESSI archdetect names '$archdetect', not $EBVM_TARGET"
[ "$EESSI_SOFTWARE_SUBDIR" = "$EBVM_TARGET" ] || refuse "EESSI selected '$EESSI_SOFTWARE_SUBDIR', not $EBVM_TARGET"
if [ -z "$EBVM_GCC_BIN" ]; then
  module load GCCcore > /dev/null 2>&1
  EBVM_GCC_BIN=gcc
fi
tmp=$(mktemp -d) || refuse "no temporary directory for the compiler probe"
case $EBVM_ARCH in
  x86_64)
    march=$("$EBVM_GCC_BIN" -march=native -Q --help=target 2> /dev/null | sed -n 's/^[[:space:]]*-march=[[:space:]]*//p' | head -n 1) ;;
  aarch64)
    echo 'int main(void){return 0;}' > "$tmp/x.c"
    march=$("$EBVM_GCC_BIN" -mcpu=native -### -c "$tmp/x.c" -o "$tmp/x.o" 2>&1 | grep -o -E -- "-mcpu=[^ \"']+" | head -n 1 | sed -e 's/^-mcpu=//' -e 's/+.*//') ;;
esac
rm -rf "$tmp"
gcc_ok=
for want in $EBVM_GCC; do [ "$march" = "$want" ] && gcc_ok=1; done
[ -n "$gcc_ok" ] || refuse "gcc native reads '$march' ($(command -v "$EBVM_GCC_BIN")), $EBVM_TARGET needs one of: $EBVM_GCC"
module load EasyBuild > /dev/null 2>&1
spec=$(python3 -c 'import archspec.cpu as c; print(c.host().name)' 2> /dev/null)
[ -n "$spec" ] || refuse "archspec is not importable after loading EasyBuild"
if [ "$spec" != "$EBVM_ARCHSPEC" ]; then
  if [ "$EBVM_ALLOW_ARCHSPEC" = 1 ]; then
    echo "eb-local: vm-run: warning: archspec reads '$spec', $EBVM_TARGET needs '$EBVM_ARCHSPEC'; accepted by --allow-archspec-mismatch" >&2
  else
    refuse "archspec reads '$spec', $EBVM_TARGET needs '$EBVM_ARCHSPEC'"
  fi
fi
msg="vendor=$vendor archdetect=$archdetect archspec=$spec gcc=$march"
echo "$msg" > "$EBVM_DIR/verified"
echo "eb-local: vm-run: $EBVM_TARGET presented: $msg" >&2
