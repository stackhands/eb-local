#!/usr/bin/env python3
"""Opt-in Zig dev replacement and leaving in real Bash and zsh processes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

import binary

GUARD_FAILURE = """#!/bin/sh
printf '%s\n' 'export EESSI_SOFTWARE_SUBDIR=wrong/from-failed-guard'
printf '%s\n' 'export EB_LOCAL_GUARD_TEST=applied'
exit 78
"""

GUARD_SUCCESS = """#!/bin/sh
printf '%s\n' 'export EB_LOCAL_GUARD_TEST=applied'
"""

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
prior_julia=$JULIA_DEPOT_PATH
prior_r=$R_LIBS_USER
prior_python=$PYTHONUSERBASE
prior_gopath=$GOPATH
prior_gomodcache=$GOMODCACHE
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
test "$JULIA_DEPOT_PATH" = "$prior_julia"
test "$R_LIBS_USER" = "$prior_r"
test "$PYTHONUSERBASE" = "$prior_python"
test "$GOPATH" = "$prior_gopath"
test "$GOMODCACHE" = "$prior_gomodcache"
test "$EB_LOCAL_DEV_GO_PREFIX" = "$CONTROL_ROOT/prior/go-prefix"
test "${LD_PRELOAD+x}" = x
test -z "$LD_PRELOAD"
test "${LD_AUDIT+x}" != x
test "${EB_LOCAL_DEV_SAVED+x}" != x

export JULIA_DEPOT_PATH=/v1/julia R_LIBS_USER=/v1/r PYTHONUSERBASE=/v1/python GOPATH=/v1/go GOMODCACHE=/v1/cache EB_LOCAL_DEV_GO_PREFIX=/v1/prefix
EB_LOCAL_DEV_SAVED=$LEGACY_STATE
export EB_LOCAL_DEV_SAVED
eval "$(eb_local leave)"
test "$PATH" = "$CONTROL_ROOT/legacy/bin"
test "$EB_LOCAL_DEV_PREFIX" = "$CONTROL_ROOT/legacy/dev"
test "${CMAKE_ARGS+x}" != x
test "${EB_LOCAL_MESON_INSTALL_RPATH+x}" != x
test "${JULIA_DEPOT_PATH+x}" != x
test "${R_LIBS_USER+x}" != x
test "${PYTHONUSERBASE+x}" != x
test "${GOPATH+x}" != x
test "${GOMODCACHE+x}" != x
test "${EB_LOCAL_DEV_GO_PREFIX+x}" != x

export JULIA_DEPOT_PATH=/v2/julia R_LIBS_USER=/v2/r PYTHONUSERBASE=/v2/python GOPATH=/v2/go GOMODCACHE=/v2/cache EB_LOCAL_DEV_GO_PREFIX=/v2/prefix
EB_LOCAL_DEV_SAVED=$V2_STATE
export EB_LOCAL_DEV_SAVED
eval "$(eb_local leave)"
test "$PATH" = "$CONTROL_ROOT/v2/bin"
test "$EB_LOCAL_DEV_PREFIX" = "$CONTROL_ROOT/v2/dev"
test "${JULIA_DEPOT_PATH+x}" != x
test "${R_LIBS_USER+x}" != x
test "${PYTHONUSERBASE+x}" != x
test "${GOPATH+x}" != x
test "${GOMODCACHE+x}" != x
test "${EB_LOCAL_DEV_GO_PREFIX+x}" != x

CMAKE_ARGS='-DUSER_FLAG=OFF -DCMAKE_SKIP_RPATH=OFF'
EB_LOCAL_MESON_INSTALL_RPATH=before-off
export CMAKE_ARGS EB_LOCAL_MESON_INSTALL_RPATH
eval "$(eb_local dev --replace --buildenv buildenv/test GCC/4)"
test "$CMAKE_ARGS" = '-DUSER_FLAG=OFF -DCMAKE_SKIP_RPATH=OFF'
eval "$(eb_local leave)"
test "$CMAKE_ARGS" = '-DUSER_FLAG=OFF -DCMAKE_SKIP_RPATH=OFF'
test "$EB_LOCAL_MESON_INSTALL_RPATH" = before-off

unset JULIA_DEPOT_PATH R_LIBS_USER PYTHONUSERBASE GOPATH GOMODCACHE EB_LOCAL_DEV_GO_PREFIX
eval "$(eb_local dev --replace --buildenv buildenv/test GCC/5)"
test -n "$JULIA_DEPOT_PATH"
test -n "$R_LIBS_USER"
test -n "$PYTHONUSERBASE"
test -n "$GOPATH"
test -n "$GOMODCACHE"
test -n "$EB_LOCAL_DEV_GO_PREFIX"
eval "$(eb_local leave)"
test "${JULIA_DEPOT_PATH+x}" != x
test "${R_LIBS_USER+x}" != x
test "${PYTHONUSERBASE+x}" != x
test "${GOPATH+x}" != x
test "${GOMODCACHE+x}" != x
test "${EB_LOCAL_DEV_GO_PREFIX+x}" != x
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
        # dev prints the Cargo linker lines, which call env, awk and tr.
        # leave can restore PATH to only the v2 bin directory, so the
        # three tools live there and the later dev can run them.
        v2bin = self.root / "v2" / "bin"
        v2bin.mkdir(parents=True)
        for name in ("env", "awk", "tr"):
            tool = v2bin / name
            tool.write_text(f"#!/bin/sh\nexec /usr/bin/{name} \"$@\"\n", encoding="utf-8")
            tool.chmod(0o755)
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
            "JULIA_DEPOT_PATH": str(self.root / "prior" / "julia"),
            "R_LIBS_USER": str(self.root / "prior" / "r"),
            "PYTHONUSERBASE": str(self.root / "prior" / "python"),
            "GOPATH": str(self.root / "prior" / "go"),
            "GOMODCACHE": str(self.root / "prior" / "go" / "pkg" / "mod"),
            "EB_LOCAL_DEV_GO_PREFIX": str(self.root / "prior" / "go-prefix"),
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
        v2_values = {
            "PATH": str(self.root / "v2" / "bin"),
            "EB_LOCAL_DEV_PREFIX": str(self.root / "v2" / "dev"),
            "EB_LOCAL_RPATH_WRAPPERS": None,
            "CMAKE_ARGS": None,
            "EB_LOCAL_MESON_INSTALL_RPATH": None,
            "LD_LIBRARY_PATH": None,
            "LD_PRELOAD": None,
            "LD_AUDIT": None,
        }
        lines = ["eb-local-dev-v2", "prior:Base/1"]
        for name, value in v2_values.items():
            encoded = "u" if value is None else "s" + value.encode().hex()
            lines.append(f"{name}:{encoded}")
        lines.append("active:Base/1")
        self.env["V2_STATE"] = "\n".join(lines)

    def command(self):
        return f'"{binary.ZIG}" "$@"'

    def dev_output(self, env):
        return self.command_output(["dev"], env)

    def command_output(self, args, env):
        emitted = subprocess.run(
            [binary.ZIG, *args],
            cwd=self.root,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(emitted.returncode, 0, emitted.stdout + emitted.stderr)
        return emitted.stdout

    def caller_script(self, emitted, reached, state=None):
        save_state = ""
        if state is not None:
            save_state = (
                '\nif [ -n "${ZSH_VERSION-}" ]; then\n'
                '  TRAPZERR() { printf "%s" "${EB_LOCAL_GUARD_TEST-unset}" > '
                f"{str(state)!r}; }}\n"
                "else\n"
                '  trap \'printf "%s" "${EB_LOCAL_GUARD_TEST-unset}" > '
                f"{str(state)!r}' EXIT\n"
                "fi\n"
            )
        return (
            "set -e\n"
            'module() { eval "$("$PYTHON" "$MODULE_STUB" "$@")"; }\n'
            + save_state
            + emitted
            + f"\nprintf '%s\\n' reached > {str(reached)!r}\n"
        )

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

    def test_failed_arch_guard_stops_errexit_callers_without_evaluating_output(self):
        bin_dir = self.root / "guard-bin"
        bin_dir.mkdir()
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(GUARD_FAILURE)
        guard.chmod(0o755)
        env = dict(self.env, PATH=f"{bin_dir}:/usr/bin:/bin")
        emitted = self.dev_output(env)

        for shell in filter(None, [shutil.which("bash"), shutil.which("zsh")]):
            with self.subTest(shell=Path(shell).name):
                reached = self.root / f"reached-{Path(shell).name}"
                state = self.root / f"state-{Path(shell).name}"
                replay = subprocess.run(
                    [shell, "-c", self.caller_script(emitted, reached, state)],
                    cwd=self.root,
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(replay.returncode, 78, replay.stdout + replay.stderr)
                self.assertFalse(reached.exists())
                self.assertEqual(state.read_text(), "unset")

    def test_failed_arch_guard_returns_from_non_errexit_eval_contexts(self):
        bin_dir = self.root / "guard-bin"
        bin_dir.mkdir()
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(GUARD_FAILURE)
        guard.chmod(0o755)
        env = dict(self.env, PATH=f"{bin_dir}:/usr/bin:/bin")
        emitted = self.dev_output(env)
        emitted_path = self.root / "dev-output.sh"
        emitted_path.write_text(emitted)
        modes = {
            "errexit-off": f'eval "$(cat {str(emitted_path)!r})"\nresult_status=$?\n',
            "or": (
                f'eval "$(cat {str(emitted_path)!r})" || '
                '{ result_status=$?; printf fallback > "$FALLBACK"; }\n'
            ),
            "if": (
                f'if eval "$(cat {str(emitted_path)!r})"; then result_status=0; '
                "else result_status=$?; fi\n"
            ),
        }

        for shell in filter(None, [shutil.which("bash"), shutil.which("zsh")]):
            for mode, invoke in modes.items():
                with self.subTest(shell=Path(shell).name, mode=mode):
                    (self.root / "module-calls").unlink(missing_ok=True)
                    result = self.root / f"result-{Path(shell).name}-{mode}"
                    fallback = self.root / f"fallback-{Path(shell).name}-{mode}"
                    script = (
                        'module() { eval "$("$PYTHON" "$MODULE_STUB" "$@")"; }\n'
                        + invoke
                        + "if typeset -f eb_local_apply >/dev/null 2>&1; "
                        "then exit 31; fi\n"
                        + 'printf "%s:%s:%s" "$result_status" "${EESSI_SOFTWARE_SUBDIR-unset}" '
                        f'"${{EB_LOCAL_GUARD_TEST-unset}}" > {str(result)!r}\n'
                        + 'exit "$result_status"\n'
                    )
                    replay = subprocess.run(
                        [shell, "-c", script],
                        cwd=self.root,
                        env=dict(env, FALLBACK=str(fallback)),
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(replay.returncode, 78, replay.stdout + replay.stderr)
                    self.assertEqual(result.read_text(), "78:x86_64/test:unset")
                    self.assertEqual(fallback.exists(), mode == "or")
                    loads = [
                        line for line in (self.root / "module-calls").read_text().splitlines()
                        if line.startswith("load ")
                    ]
                    self.assertFalse(any("EESSI-extend" in line for line in loads), loads)

    def test_passing_arch_guard_applies_its_output(self):
        bin_dir = self.root / "guard-bin"
        bin_dir.mkdir()
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(GUARD_SUCCESS)
        guard.chmod(0o755)
        env = dict(self.env, PATH=f"{bin_dir}:/usr/bin:/bin")
        emitted = self.dev_output(env)

        for shell in filter(None, [shutil.which("bash"), shutil.which("zsh")]):
            with self.subTest(shell=Path(shell).name):
                reached = self.root / f"reached-{Path(shell).name}"
                script = self.caller_script(
                    emitted
                    + '\ntest "$EB_LOCAL_GUARD_TEST" = applied\n'
                    + "if typeset -f eb_local_apply >/dev/null 2>&1; "
                    "then exit 31; fi\n",
                    reached,
                )
                replay = subprocess.run(
                    [shell, "-c", script],
                    cwd=self.root,
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
                self.assertTrue(reached.exists())

    def test_failed_replace_keeps_state_for_leave_and_retry(self):
        bin_dir = self.root / "guard-bin"
        bin_dir.mkdir()
        mode = self.root / "guard-mode"
        mode.write_text("fail")
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(
            "#!/bin/sh\n"
            'if [ "$(cat "$GUARD_MODE")" = fail ]; then\n'
            "  printf '%s\\n' 'export EESSI_SOFTWARE_SUBDIR=wrong'\n"
            "  exit 78\n"
            "fi\n"
            "printf '%s\\n' 'export EESSI_SOFTWARE_SUBDIR=x86_64/test'\n"
        )
        guard.chmod(0o755)
        env = dict(
            self.env,
            PATH=f"{bin_dir}:/usr/bin:/bin",
            GUARD_MODE=str(mode),
            EB_LOCAL_DEV_SAVED=self.env["LEGACY_STATE"],
        )
        failed = self.command_output(["dev", "--replace"], env)
        failed_path = self.root / "failed-replace.sh"
        failed_path.write_text(failed)
        modes = {
            "off": f'eval "$(cat {str(failed_path)!r})"; rc=$?\n',
            "or": f'eval "$(cat {str(failed_path)!r})" || rc=$?\n',
            "if": f'if eval "$(cat {str(failed_path)!r})"; then rc=0; else rc=$?; fi\n',
        }
        shells = [s for s in (shutil.which("bash"), shutil.which("zsh")) if s]
        prefix = (
            'module() { eval "$("$PYTHON" "$MODULE_STUB" "$@")"; }\n'
            + f'eb_local() {{ {self.command()} ; }}\n'
            + f'printf fail > {str(mode)!r}\n'
        )
        after_fail = (
            '[ "$rc" = 78 ] || exit 20\n'
            + "if typeset -f eb_local_apply >/dev/null 2>&1; "
            "then exit 31; fi\n"
            + 'eval "$(eb_local leave)" || exit 21\n'
            + '[ "$LOADEDMODULES" = Base/1 ] || exit 22\n'
            + f'[ "$PATH" = {str(self.root / "legacy" / "bin")!r} ] || exit 24\n'
        )
        retry = (
            f'printf pass > {str(mode)!r}\n'
            + 'eval "$(eb_local dev --replace)" || exit 23\n'
            + "if typeset -f eb_local_apply >/dev/null 2>&1; "
            "then exit 32; fi\n"
            + 'test -n "$EB_LOCAL_DEV_SAVED" || exit 25\n'
            + 'eval "$(eb_local leave)" || exit 26\n'
        )
        plans = [(shells[0], list(modes.items()), True)]
        if len(shells) > 1:
            plans.append((shells[1], [("off", modes["off"])], False))
        for shell, shapes, do_retry in plans:
            for name, invoke in shapes:
                with self.subTest(shell=Path(shell).name, mode=name):
                    script = prefix + invoke + after_fail + (retry if do_retry else "")
                    run = subprocess.run(
                        [shell, "-c", script],
                        cwd=self.root,
                        env=env,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_failed_replace_from_new_and_active_shell_restores_and_retries(self):
        bin_dir = self.root / "guard-bin"
        bin_dir.mkdir()
        mode = self.root / "guard-mode"
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(
            "#!/bin/sh\n"
            'if [ "$(cat "$GUARD_MODE")" = fail ]; then\n'
            "  printf '%s\\n' 'export EESSI_SOFTWARE_SUBDIR=wrong'\n"
            "  exit 78\n"
            "fi\n"
            "printf '%s\\n' 'export EESSI_SOFTWARE_SUBDIR=x86_64/test'\n"
        )
        guard.chmod(0o755)
        env = dict(
            self.env,
            PATH=f"{bin_dir}:/usr/bin:/bin",
            GUARD_MODE=str(mode),
        )
        modes = {
            "off": 'eval "$(eb_local dev --replace)"; rc=$?\n',
            "or": 'eval "$(eb_local dev --replace)" || rc=$?\n',
            "if": (
                'if eval "$(eb_local dev --replace)"; then rc=0; '
                "else rc=$?; fi\n"
            ),
        }
        starts = {
            "new": "",
            "active": (
                f'printf pass > {str(mode)!r}\n'
                'eval "$(eb_local dev --replace GCC/1)" || exit 10\n'
                "if typeset -f eb_local_apply >/dev/null 2>&1; "
                "then exit 30; fi\n"
            ),
        }
        shells = [s for s in (shutil.which("bash"), shutil.which("zsh")) if s]
        plans = [(shells[0], list(starts.items()), list(modes.items()))]
        if len(shells) > 1:
            plans.append((shells[1], list(starts.items()), [("off", modes["off"])]))
        for shell, start_rows, shape_rows in plans:
            for start, prepare in start_rows:
                for shape, invoke in shape_rows:
                    with self.subTest(
                        shell=Path(shell).name,
                        start=start,
                        shape=shape,
                    ):
                        script = (
                            'module() { eval "$("$PYTHON" "$MODULE_STUB" "$@")"; }\n'
                            + f'eb_local() {{ {self.command()} ; }}\n'
                            + "prior_path=$PATH\n"
                            + prepare
                            + f'printf fail > {str(mode)!r}\n'
                            + invoke
                            + '[ "$rc" = 78 ] || exit 20\n'
                            + "if typeset -f eb_local_apply >/dev/null 2>&1; "
                            "then exit 31; fi\n"
                            + 'eval "$(eb_local leave)" || exit 21\n'
                            + '[ "$LOADEDMODULES" = Base/1 ] || exit 22\n'
                            + '[ "$PATH" = "$prior_path" ] || exit 23\n'
                            + f'printf pass > {str(mode)!r}\n'
                            + 'eval "$(eb_local dev --replace GCC/2)" || exit 24\n'
                            + "if typeset -f eb_local_apply >/dev/null 2>&1; "
                            "then exit 32; fi\n"
                            + 'test -n "$EB_LOCAL_DEV_SAVED" || exit 25\n'
                            + 'eval "$(eb_local leave)" || exit 26\n'
                            + '[ "$LOADEDMODULES" = Base/1 ] || exit 27\n'
                            + '[ "$PATH" = "$prior_path" ] || exit 28\n'
                        )
                        run = subprocess.run(
                            [shell, "-c", script],
                            cwd=self.root,
                            env=env,
                            check=False,
                            capture_output=True,
                            text=True,
                        )
                        self.assertEqual(
                            run.returncode,
                            0,
                            run.stdout + run.stderr,
                        )


if __name__ == "__main__":
    unittest.main()
