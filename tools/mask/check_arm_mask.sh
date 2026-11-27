#!/usr/bin/env bash
# Checks the cpuid route's aarch64 mask on real Arm silicon, without EESSI:
# under __mask-run, getauxval, /proc/cpuinfo and gcc -mcpu=native must name
# the target profile. Usage: check_arm_mask.sh EB_LOCAL_BINARY [TARGET...]
set -euo pipefail

eb=${1:?usage: check_arm_mask.sh EB_LOCAL_BINARY [TARGET...]}
shift
[ "$(uname -m)" = aarch64 ] || { echo "check_arm_mask: this host is $(uname -m), not aarch64" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
profiles=$here/../../share/eb-local/mask/profiles.conf
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(aarch64/neoverse_n1 aarch64/generic)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/hwcap.c" <<'C'
#include <stdio.h>
#include <sys/auxv.h>
int main(void)
{
    printf("hwcap=0x%lx hwcap2=0x%lx\n", getauxval(AT_HWCAP), getauxval(AT_HWCAP2));
    return 0;
}
C
cat > "$work/x.c" <<'C'
int add(int a, int b) { return a + b; }
C
cat > "$work/inner.sh" <<'SH'
#!/usr/bin/env bash
# runs inside the mask: $1 is the work directory
grep -m1 'CPU part' /proc/cpuinfo
grep -m1 '^Features' /proc/cpuinfo
"$1/hwcap"
gcc -mcpu=native -Q --help=target -x c /dev/null -c -o /dev/null |
    awk '$1 == "-mcpu=" { print "gcc_q " $2 }'
gcc -mcpu=native -### -c "$1/x.c" -o /dev/null 2>&1 |
    grep -o -- '-mcpu=[^ "]*' | head -n 1 | sed 's/^/gcc_cc1 /'
SH
cc -O1 -o "$work/hwcap" "$work/hwcap.c"

echo "host: $(grep -m1 'CPU part' /proc/cpuinfo), $(grep -m1 '^Features' /proc/cpuinfo)"
echo "host: $("$work/hwcap")"
echo "host: gcc $(gcc -dumpfullversion), -mcpu=$(gcc -mcpu=native -Q --help=target | awk '$1 == "-mcpu=" { print $2 }')"
host_hwcap=$("$work/hwcap" | sed -n 's/^hwcap=\(0x[0-9a-f]*\) .*/\1/p')

# profile TARGET KEY: the value of KEY in the [TARGET] section of profiles.conf
profile() {
    awk -v sec="[$1]" -v key="$2" '
        $0 == sec { in_sec = 1; next }
        /^\[/ { in_sec = 0 }
        in_sec && $1 == key { sub(/^[^=]*= */, ""); print; exit }' "$profiles"
}

fail=0
for t in "${targets[@]}"; do
    part=$(profile "$t" cpu_part)
    gcc_cpu=$(profile "$t" gcc_cpu)
    keep=$(profile "$t" hwcap)
    [ -n "$part" ] && [ -n "$gcc_cpu" ] && [ -n "$keep" ] || { echo "FAIL $t: no profile in $profiles" >&2; fail=1; continue; }
    echo "=== $t: CPU part $part, -mcpu=$gcc_cpu, AT_HWCAP kept $keep"

    out=$("$eb" __mask-run --cpu-target "$t" --mask cpuid -- bash "$work/inner.sh" "$work")
    printf '%s\n' "$out" | sed 's/^/  /'

    got_part=$(printf '%s\n' "$out" | sed -n 's/^CPU part[[:space:]]*:[[:space:]]*//p')
    got_hwcap=$(printf '%s\n' "$out" | sed -n 's/^hwcap=\(0x[0-9a-f]*\) .*/\1/p')
    got_q=$(printf '%s\n' "$out" | sed -n 's/^gcc_q //p')
    got_cc1=$(printf '%s\n' "$out" | sed -n 's/^gcc_cc1 -mcpu=//p')

    [ "$got_part" = "$part" ] || { echo "FAIL $t: /proc/cpuinfo CPU part is '$got_part', want $part" >&2; fail=1; }
    # the mask keeps the real word AND the profile's: nothing outside the profile survives
    want_hwcap=$(printf '0x%x' $((host_hwcap & keep)))
    [ "$got_hwcap" = "$want_hwcap" ] || { echo "FAIL $t: masked AT_HWCAP is '$got_hwcap', want $want_hwcap (host $host_hwcap & $keep)" >&2; fail=1; }
    [ $(( got_hwcap & ~keep )) -eq 0 ] || { echo "FAIL $t: masked AT_HWCAP $got_hwcap carries bits outside $keep" >&2; fail=1; }
    # GCC appends +extension names to the CPU; the CPU is the part before the first +
    [ "${got_q%%+*}" = "$gcc_cpu" ] || { echo "FAIL $t: gcc -mcpu=native -Q reports '$got_q', want $gcc_cpu" >&2; fail=1; }
    [ "${got_cc1%%+*}" = "$gcc_cpu" ] || { echo "FAIL $t: compiling with gcc -mcpu=native passes -mcpu=$got_cc1, want $gcc_cpu" >&2; fail=1; }
    [ "$fail" -eq 0 ] && echo "ok   $t"
done
exit "$fail"
