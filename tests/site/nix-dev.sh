#!/bin/bash
# Link a library that lives outside the Nix store from nix-shell, then try
# the same link in a sandboxed nix-build. Prints one fact per line.
set -euo pipefail
if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
command -v nix-shell >/dev/null
command -v nix-build >/dev/null
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/lib" "$root/src"
cat > "$root/answer.c" << 'EOF'
int answer(void) { return 42; }
EOF
/usr/bin/gcc -shared -fPIC -o "$root/lib/libanswer.so" "$root/answer.c"
cat > "$root/src/t.c" << 'EOF'
int answer(void);
int main(void) { return answer() == 42 ? 0 : 1; }
EOF
flags="-L$root/lib -lanswer -Wl,-rpath,$root/lib -Wl,--disable-new-dtags"
# The inner nix-shell expands NIX_ENFORCE_PURITY. This shell must leave it quoted.
# shellcheck disable=SC2016
purity=$(nix-shell -p gcc --run 'printf %s "${NIX_ENFORCE_PURITY-unset}"')
nix-shell -p gcc --run "gcc $root/src/t.c $flags -o $root/impure"
dump=$(readelf -d "$root/impure")
case "$dump" in
    *'(RUNPATH)'*) echo "impure shell recorded RUNPATH" >&2; exit 1 ;;
esac
case "$dump" in
    *'(RPATH)'*"$root/lib"*) ;;
    *) echo "impure shell dropped the outside directory" >&2; exit 1 ;;
esac
case "$dump" in
    *'(RPATH)'*'/nix/store/'*'glibc-'*) ;;
    *) echo "impure shell omitted the Nix glibc directory" >&2; exit 1 ;;
esac
interp=$(readelf -l "$root/impure" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
case "$interp" in
    /nix/store/*) ;;
    *) echo "interpreter is $interp" >&2; exit 1 ;;
esac
env -i PATH=/usr/bin:/bin "$root/impure"
nix-shell --pure -p gcc --run "gcc $root/src/t.c $flags -o $root/pure"
pdump=$(readelf -d "$root/pure")
case "$pdump" in
    *'(RUNPATH)'*) echo "pure shell recorded RUNPATH" >&2; exit 1 ;;
esac
case "$pdump" in
    *'(RPATH)'*"$root/lib"*) ;;
    *) echo "pure shell dropped the outside directory" >&2; exit 1 ;;
esac
cat > "$root/src/default.nix" << EOF
let pkgs = import <nixpkgs> {};
in pkgs.stdenv.mkDerivation {
  name = "answer-link";
  src = ./.;
  buildPhase = ''
    gcc t.c -L${root}/lib -lanswer -Wl,-rpath,${root}/lib -Wl,--disable-new-dtags -o a.out
  '';
  installPhase = "mkdir -p \$out";
}
EOF
set +e
nix-build "$root/src/default.nix" --no-out-link > "$root/sandbox.log" 2>&1
code=$?
set -e
if [ "$code" -eq 0 ]; then
    echo "sandboxed nix-build linked the outside library" >&2
    exit 1
fi
if ! grep -q 'cannot find -lanswer' "$root/sandbox.log"; then
    echo "sandbox log did not report the missing library" >&2
    cat "$root/sandbox.log" >&2
    exit 1
fi
host=$(/usr/bin/ldd --version | awk 'NR==1 { print $NF }')
nixglibc=$(printf '%s\n' "$dump" | sed -n 's/.*glibc-\([0-9.][0-9.]*\).*/\1/p' | head -n 1)
printf 'nix-version:%s\n' "$(nix --version | awk 'NR==1 { print $NF }')"
printf 'host-glibc:%s\n' "$host"
printf 'nix-glibc:%s\n' "$nixglibc"
printf 'impure-rpath-kept:1\n'
printf 'pure-rpath-kept:1\n'
printf 'runpath-absent:1\n'
printf 'unloaded-exit:0\n'
printf 'sandbox-cannot-find:1\n'
printf 'nix-enforce-purity:%s\n' "$purity"
printf 'interpreter:%s\n' "$interp"
