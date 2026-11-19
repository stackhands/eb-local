#!/bin/bash
# Site acceptance for the run-paths page: Cargo, Julia, Node.js, R and a
# Python virtual environment on EESSI 2026.06. Each task starts from a purged
# module environment. The built program is then run with env -i, no modules
# and no LD_LIBRARY_PATH, and its run path must point into EESSI.
#
#   EB_LOCAL_TEST_ROOT=DIR [EB_LOCAL_BIN=eb-local] bash tests/site/lang-dev-tasks.sh
#
# DIR holds eb-local.conf and receives eessi/ and work/. Remove it afterwards.
# Cargo, Julia, Node and the Python extension need no network. R CMD INSTALL
# builds the tiny package in the work directory.
set -o pipefail
T=${EB_LOCAL_TEST_ROOT:?set EB_LOCAL_TEST_ROOT to a scratch directory}
EL=${EB_LOCAL_BIN:-$(dirname "$(readlink -f "$0")")/../../eb-local}
export EB_LOCAL_CONFIG=$T/eb-local.conf EB_LOCAL_PREFIX=$T/eessi
W=$T/work
rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
bare() { env -i HOME="$HOME" PATH=/usr/bin:/bin "$@"; }
eessi_runpath() { readelf -d "$1" | grep -E 'RPATH|RUNPATH' | grep -q "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/.*/$2/"; }
from_eessi() { case "$(command -v "$1")" in "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}"/*) ;; *) echo "$1 is $(command -v "$1"), not EESSI's"; return 1;; esac; }
task() {
    local name="$1"; shift
    if ( set -e; module purge >/dev/null 2>&1; unset LD_LIBRARY_PATH; "$@" ) > "$W/$name.log" 2>&1; then
        echo "PASS $name"; pass=$((pass + 1))
    else
        echo "FAIL $name (see $W/$name.log)"; tail -5 "$W/$name.log" | sed 's/^/    /'; fail=$((fail + 1))
    fi
}

# The same linker assignment eb-local eb makes, after the host values are gone.
cargo_linker() {
    unset RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
    eval "$(env | awk -F= '/^CARGO_TARGET_[A-Z0-9_]*_(LINKER|RUSTFLAGS)=/{print "unset "$1}')"
    export LINKER="${CC:-gcc}"
    _triple=$(rustc -vV | awk '/^host:/{print $2}')
    _triple_env=$(printf %s "${_triple}" | tr '[:lower:]-' '[:upper:]_')
    eval "export CARGO_TARGET_${_triple_env}_LINKER=\${CC:-gcc}"
}

t_cargo() {
    eval "$($EL dev Rust/1.94.1-GCCcore-15.2.0)"
    module is-loaded buildenv/default-foss-2026.1
    from_eessi rustc
    from_eessi cargo
    from_eessi gcc
    cargo_linker
    export CARGO_HOME="$W/cargo-home"
    mkdir -p "$W/hello/src"
    cat > "$W/hello/Cargo.toml" << 'EOF'
[package]
name = "hello"
version = "0.0.1"
edition = "2021"
EOF
    printf '%s\n' 'fn main() { println!("ok"); }' > "$W/hello/src/main.rs"
    ( cd "$W/hello" && cargo build --offline )
    eessi_runpath "$W/hello/target/debug/hello" GCCcore
    bare "$W/hello/target/debug/hello"
}

t_julia() {
    eval "$($EL dev Julia/1.13.2)"
    module is-loaded buildenv/default-foss-2026.1
    from_eessi julia
    from_eessi gcc
    if [ -z "${JULIA_DEPOT_PATH:-}" ]; then
        export JULIA_DEPOT_PATH="$EB_LOCAL_DEV_PREFIX/julia"
    fi
    mkdir -p "$JULIA_DEPOT_PATH"
    printf '%s\n' 'int answer(void) { return 42; }' > "$W/answer.c"
    gcc -shared -fPIC -o "$W/libanswer.so" "$W/answer.c"
    eessi_runpath "$W/libanswer.so" GCCcore
    cat > "$W/answer.jl" << EOF
ccall((:answer, "$W/libanswer.so"), Cint, ()) == 42 || error("answer")
EOF
    julia "$W/answer.jl"
}

t_node() {
    eval "$($EL dev nodejs/24.16.0-GCCcore-15.2.0)"
    module is-loaded buildenv/default-foss-2026.1
    from_eessi node
    from_eessi gcc
    unset NODE_PATH
    root=$(dirname "$(dirname "$(readlink -f "$(command -v node)")")")
    cat > "$W/addon.c" << 'EOF'
#include <node_api.h>
static napi_value init(napi_env env, napi_value exports) {
    napi_value v;
    napi_create_int32(env, 42, &v);
    napi_set_named_property(env, exports, "answer", v);
    return exports;
}
NAPI_MODULE(addon, init)
EOF
    gcc -shared -fPIC -I"$root/include/node" -o "$W/addon.node" "$W/addon.c"
    eessi_runpath "$W/addon.node" GCCcore
    bare "$(command -v node)" -e "const a = require('$W/addon.node'); if (a.answer !== 42) process.exit(1)"
}

t_r_makevars() {
    unset R_MAKEVARS_USER R_MAKEVARS_SITE
    eval "$($EL dev R/4.6.1-gfbf-2026.1)"
    module is-loaded buildenv/default-foss-2026.1
    from_eessi R
    cc=$(R CMD config CC)
    case "$cc" in
        gcc | gcc\ *) ;;
        *) echo "R CC is $cc"; return 1 ;;
    esac
    mkdir -p "$W/pkga/src" "$W/rlib"
    cat > "$W/pkga/DESCRIPTION" << 'EOF'
Package: pkga
Version: 0.0.1
Title: Tiny Compiled Package
Description: A one-function package built to check the run path.
License: MIT
NeedsCompilation: yes
EOF
    printf '%s\n' 'useDynLib(pkga)' > "$W/pkga/NAMESPACE"
    printf '%s\n' 'void pkga_noop(void) {}' > "$W/pkga/src/pkga.c"
    R CMD INSTALL --library="$W/rlib" "$W/pkga"
    so=$(find "$W/rlib/pkga/libs" -name '*.so' -print -quit)
    test -n "$so"
    eessi_runpath "$so" GCCcore
    bare "$(command -v Rscript)" -e "dyn.load('$so'); cat('pkga ok\n')"
}

t_python_venv() {
    unset PYTHONPATH
    unset CC
    unset CXX
    eval "$($EL dev Python/3.14.2-GCCcore-15.2.0)"
    module is-loaded buildenv/default-foss-2026.1
    from_eessi python
    from_eessi gcc
    python -m venv "$W/py"
    cc=$("$W/py/bin/python" -c 'import sysconfig; print(sysconfig.get_config_var("CC").split()[0])')
    case "$cc" in
        gcc) ;;
        *) echo "venv CC is $cc"; return 1 ;;
    esac
    inc=$("$W/py/bin/python" -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))')
    cat > "$W/ext.c" << 'EOF'
#define PY_SSIZE_T_CLEAN
#include <Python.h>
static PyObject *answer(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;
    return PyLong_FromLong(42);
}
static PyMethodDef methods[] = {
    {"answer", answer, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL},
};
static struct PyModuleDef def = {PyModuleDef_HEAD_INIT, "ext", NULL, -1, methods};
PyMODINIT_FUNC PyInit_ext(void) { return PyModule_Create(&def); }
EOF
    "$cc" -shared -fPIC -I"$inc" -o "$W/ext.so" "$W/ext.c"
    eessi_runpath "$W/ext.so" GCCcore
    bare "$W/py/bin/python" -c "import sys; sys.path.insert(0, '$W'); import ext; assert ext.answer() == 42"
}

task cargo t_cargo
task julia t_julia
task node t_node
task r-makevars t_r_makevars
task python-venv t_python_venv
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
