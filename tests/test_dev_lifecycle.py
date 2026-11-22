#!/usr/bin/env python3
"""Opt-in Zig dev replacement and leaving in real Bash and zsh processes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

import binary

MODULE_STUB = r"""#!/usr/bin/env python3
import os
from pathlib import Path
import shlex
import sys

root = Path(os.environ["CONTROL_ROOT"])
op, *names = sys.argv[1:]
with (root / "module-calls").open("a") as stream:
    print(" ".join((op, *names)), file=stream)

modules = [item for item in os.environ.get("LOADEDMODULES", "").split(":") if item]
path = os.environ.get("PATH", "").split(":")
libraries = os.environ.get("LD_LIBRARY_PATH", "").split(":")

def locations(module):
    if module.startswith("GCC/"):
        return str(root / "gcc" / "bin"), str(root / "gcc" / "lib")
    if module.startswith("llvm-compilers/"):
        return str(root / "llvm" / "bin"), str(root / "llvm" / "lib")
    return None

if op == "load":
    for name in names:
        if name not in modules:
            modules.append(name)
        found = locations(name)
        if found:
            path = [found[0], *[item for item in path if item != found[0]]]
            libraries = [found[1], *[item for item in libraries if item != found[1]]]
elif op == "unload":
    for name in names:
        modules = [item for item in modules if item != name]
        found = locations(name)
        if found:
            path = [item for item in path if item != found[0]]
            libraries = [item for item in libraries if item != found[1]]
elif op == "is-avail":
    raise SystemExit(1)

for name, value in (
    ("LOADEDMODULES", ":".join(modules)),
    ("PATH", ":".join(path)),
    ("LD_LIBRARY_PATH", ":".join(libraries)),
):
    print(f"export {name}={shlex.quote(value)}")
"""

LIFECYCLE = r"""
set -eu
set -o pipefail
module() {
    eval "$("$PYTHON" "$MODULE_STUB" "$@")"
}
eb_local() {
    __EB_LOCAL_COMMAND__
}
contains_module() {
    case ":${LOADEDMODULES-}:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

prior_path=$PATH
prior_cmake=$CMAKE_ARGS
prior_meson=$EB_LOCAL_MESON_INSTALL_RPATH
eval "$(eb_local dev --replace --buildenv buildenv/test GCC/1)"
contains_module Base/1
contains_module GCC/1
test -n "$EB_LOCAL_DEV_SAVED"
test "$CMAKE_ARGS" = "-DCMAKE_SKIP_RPATH=ON $prior_cmake"
test "$EB_LOCAL_MESON_INSTALL_RPATH" = "$CONTROL_ROOT/meson/lib"
active_cmake=$CMAKE_ARGS
active_meson=$EB_LOCAL_MESON_INSTALL_RPATH

eval "$(eb_local dev --replace --buildenv buildenv/test llvm-compilers/2)"
contains_module Base/1
contains_module llvm-compilers/2
if contains_module GCC/1; then exit 20; fi
test "$CMAKE_ARGS" = "$active_cmake"
test "$EB_LOCAL_MESON_INSTALL_RPATH" = "$active_meson"

eval "$(eb_local dev --replace --buildenv buildenv/test GCC/3)"
contains_module Base/1
contains_module GCC/3
if contains_module llvm-compilers/2; then exit 21; fi
test "$CMAKE_ARGS" = "$active_cmake"
test "$EB_LOCAL_MESON_INSTALL_RPATH" = "$active_meson"

eval "$(eb_local leave)"
test "$LOADEDMODULES" = Base/1
test "$PATH" = "$prior_path"
test "$LD_LIBRARY_PATH" = "$CONTROL_ROOT/prior/lib"
test "$EB_LOCAL_DEV_PREFIX" = "$CONTROL_ROOT/prior/dev"
test "$EB_LOCAL_RPATH_WRAPPERS" = "$CONTROL_ROOT/prior wrappers"
test "$CMAKE_ARGS" = "$prior_cmake"
test "$EB_LOCAL_MESON_INSTALL_RPATH" = "$prior_meson"
test "${LD_PRELOAD+x}" = x
test -z "$LD_PRELOAD"
test "${LD_AUDIT+x}" != x
test "${EB_LOCAL_DEV_SAVED+x}" != x

EB_LOCAL_DEV_SAVED=$LEGACY_STATE
export EB_LOCAL_DEV_SAVED
eval "$(eb_local leave)"
test "$PATH" = "$CONTROL_ROOT/legacy/bin"
test "$EB_LOCAL_DEV_PREFIX" = "$CONTROL_ROOT/legacy/dev"
test "${CMAKE_ARGS+x}" != x
test "${EB_LOCAL_MESON_INSTALL_RPATH+x}" != x

CMAKE_ARGS='-DUSER_FLAG=OFF -DCMAKE_SKIP_RPATH=OFF'
EB_LOCAL_MESON_INSTALL_RPATH=before-off
export CMAKE_ARGS EB_LOCAL_MESON_INSTALL_RPATH
eval "$(eb_local dev --replace --buildenv buildenv/test GCC/4)"
test "$CMAKE_ARGS" = '-DUSER_FLAG=OFF -DCMAKE_SKIP_RPATH=OFF'
eval "$(eb_local leave)"
test "$CMAKE_ARGS" = '-DUSER_FLAG=OFF -DCMAKE_SKIP_RPATH=OFF'
test "$EB_LOCAL_MESON_INSTALL_RPATH" = before-off
"""


@unittest.skipUnless(binary.ZIG, "Zig lifecycle checks need the Zig build")
class DevLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-dev-lifecycle-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.stub = self.root / "module-stub.py"
        self.stub.write_text(MODULE_STUB)
        self.stub.chmod(0o755)
        prior = self.root / "prior bin's\nnext"
        prior.mkdir()
        self.env = {
            "HOME": str(self.root),
            "PATH": f"{prior}:/usr/bin:/bin",
            "EB_LOCAL_PREFIX": str(self.root / "prefix"),
            "LOADEDMODULES": "Base/1",
            "LD_LIBRARY_PATH": str(self.root / "prior" / "lib"),
            "LD_PRELOAD": "",
            "EB_LOCAL_DEV_PREFIX": str(self.root / "prior" / "dev"),
            "EB_LOCAL_RPATH_WRAPPERS": str(self.root / "prior wrappers"),
            "CMAKE_ARGS": "-DUSER_FLAG=ON",
            "EB_LOCAL_MESON_INSTALL_RPATH": "prior-meson",
            "LIBRARY_PATH": (
                f"{self.root}/meson/lib:/usr/lib:{self.root}/compat/lib"
            ),
            "EESSI_EPREFIX": str(self.root / "compat"),
            "EESSI_VERSION": "2026.06",
            "EESSI_SOFTWARE_SUBDIR": "x86_64/test",
            "CONTROL_ROOT": str(self.root),
            "MODULE_STUB": str(self.stub),
            "PYTHON": shutil.which("python3"),
        }
        values = {
            "PATH": str(self.root / "legacy" / "bin"),
            "EB_LOCAL_DEV_PREFIX": str(self.root / "legacy" / "dev"),
            "EB_LOCAL_RPATH_WRAPPERS": None,
            "LD_LIBRARY_PATH": str(self.root / "legacy" / "lib"),
            "LD_PRELOAD": None,
            "LD_AUDIT": None,
        }
        lines = ["eb-local-dev-v1", "prior:Base/1"]
        for name, value in values.items():
            encoded = "u" if value is None else "s" + value.encode().hex()
            lines.append(f"{name}:{encoded}")
        lines.append("active:Base/1")
        self.env["LEGACY_STATE"] = "\n".join(lines)

    def command(self):
        return f'"{binary.ZIG}" "$@"'

    def test_replace_switches_compilers_and_leave_restores_the_caller(self):
        script = self.root / "lifecycle.sh"
        script.write_text(textwrap.dedent(LIFECYCLE).replace("__EB_LOCAL_COMMAND__", self.command()))
        shells = [shutil.which("bash"), shutil.which("zsh")]
        for shell in filter(None, shells):
            with self.subTest(shell=Path(shell).name):
                (self.root / "module-calls").unlink(missing_ok=True)
                run = subprocess.run(
                    [shell, str(script)],
                    cwd=self.root,
                    env=self.env,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                unloads = [
                    line.split()[1:]
                    for line in (self.root / "module-calls").read_text().splitlines()
                    if line.startswith("unload ")
                ]
                self.assertTrue(any("GCC/1" in names for names in unloads), unloads)
                self.assertTrue(any("llvm-compilers/2" in names for names in unloads), unloads)
                self.assertFalse(any("Base/1" in names for names in unloads), unloads)

    def test_leave_refuses_missing_and_malformed_state(self):
        argv = [binary.ZIG, "leave"]
        for state in (None, "not a state"):
            env = dict(self.env)
            if state is not None:
                env["EB_LOCAL_DEV_SAVED"] = state
            got = subprocess.run(argv, env=env, capture_output=True, text=True)
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            self.assertEqual(got.stdout, "")
            self.assertIn("EB_LOCAL_DEV_SAVED" if state else "no recorded dev", got.stderr)


if __name__ == "__main__":
    unittest.main()
