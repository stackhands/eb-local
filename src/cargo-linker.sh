unset RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS \
  CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CMAKE_Fortran_COMPILER_LAUNCHER || true
eval "$(env | awk -F= '/^CARGO_TARGET_[A-Z0-9_]*_(LINKER|RUSTFLAGS)=/{print "unset "$1}')"
export LINKER=${CC:-gcc}
_triple=""
if _host=$(rustc -vV 2>/dev/null); then
  _triple=$(printf '%s\n' "$_host" | awk '/^host:/{print $2}')
fi
_triple_env=$(printf %s "${_triple}" | tr '[:lower:]-' '[:upper:]_')
if [[ -n ${_triple_env} ]]; then
  eval "export CARGO_TARGET_${_triple_env}_LINKER=\${CC:-gcc}"
fi
