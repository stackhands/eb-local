#!/usr/bin/env python3
"""Behavioral checks for the environment eb-local selects.

The module and eb doubles verify wrapper routing and argument preservation.
They do not establish the destination chosen by a native EESSI extension.
The module double refuses, as Lmod 9.4.5 does, a load that names
EESSI-extend while EESSI is not loaded yet; the EESSI load sets the CPU
target. The eessi-arch-guard double selects another target, as the guard
does on a CPU that lacks a flag GCC enables for the detected one.
"""
import json
import os
import pwd
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import binary

SCRIPT = Path(__file__).resolve().parents[1] / "eb-local"
CLEAR = (
    "EESSI_CVMFS_INSTALL", "EESSI_SITE_INSTALL", "EESSI_USER_INSTALL", "EESSI_PROJECT_INSTALL",
    "EESSI_SITE_SOFTWARE_PREFIX", "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
    "EESSI_ACCELERATOR_TARGET_OVERRIDE", "EESSI_OVERRIDE_GPU_CHECK",
    "EASYBUILD_INSTALLPATH", "EASYBUILD_INSTALLPATH_SOFTWARE",
    "EASYBUILD_INSTALLPATH_MODULES", "EASYBUILD_PREFIX",
)
DOUBLE = r'''
module() {
    if [ "$1" = unload ]; then
        # Model values restored when an existing extension is unloaded.
        for name in $CONTROL_CLEAR; do export "$name=restored-by-unload"; done
        return 0
    fi
    if [ "$1" = load ]; then
        python3 "$CONTROL_ROOT/capture.py" load "$@" || return
        export CONTROL_LOADED="${CONTROL_LOADED-} ${*:2}"
        if [ "$2" = EESSI/2026.06 ]; then
            export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4
            export EESSI_ACCELERATOR_TARGET=
        fi
        export EASYBUILD_HOOKS=/selected/eessi/eb_hooks.py
        return 0
    fi
    return 99
}
eb() {
    python3 "$CONTROL_ROOT/capture.py" eb "$@"
}
# Scope the wrapper's scratch operations to the fixture's filesystem.
mkdir() {
    local rewritten=() arg
    for arg in "$@"; do
        case "$arg" in /scratch-shared/*) arg="$CONTROL_ROOT/scratch${arg#/scratch-shared}";; esac
        rewritten+=("$arg")
    done
    command mkdir "${rewritten[@]}"
}
cd() {
    case "${1-}" in
        /scratch-shared/*) builtin cd "$CONTROL_ROOT/scratch${1#/scratch-shared}";;
        *) builtin cd "$@";;
    esac
}
export -f module eb mkdir cd
findmnt() {
    case "$3" in
        FSTYPE) printf '%s\n' xfs;;
        TARGET) printf '%s\n' "$CONTROL_JOB_ROOT";;
        OPTIONS) printf '%s\n' rw,relatime;;
        *) return 99;;
    esac
}
export -f findmnt
'''
CAPTURE = r'''
import json, os, sys
from pathlib import Path
kind = sys.argv[1]
root = Path(os.environ["CONTROL_ROOT"])
names = os.environ["CONTROL_CLEAR"].split()
values = {name: os.environ[name] for name in names if name in os.environ}
if kind == "load":
    expected = {os.environ["CONTROL_MODE"]: os.environ["CONTROL_PREFIX"]}
    if values != expected:
        print("unexpected load environment: " + repr(values), file=sys.stderr)
        sys.exit(96)
    names = sys.argv[3:]
    # EESSI-extend is on MODULEPATH only once EESSI is loaded, and Lmod finds
    # every module of a load before it loads any: naming both in one call
    # fails and loads neither.
    if "EESSI-extend/2026.06-easybuild" in names and "EESSI/2026.06" not in os.environ.get("CONTROL_LOADED", "").split():
        print('Lmod has detected the following error: These module(s) or extension(s) exist '
              'but cannot be loaded as requested: "EESSI-extend/2026.06-easybuild"', file=sys.stderr)
        sys.exit(1)
    if names not in (["EESSI/2026.06"], ["EESSI-extend/2026.06-easybuild"]):
        sys.exit(97)
    record = root / "load.json"
    calls = json.loads(record.read_text())["calls"] if record.exists() else []
    record.write_text(json.dumps({"env": values, "calls": calls + [names]}))
else:
    if os.environ.get("EASYBUILD_HOOKS") != "/selected/eessi/eb_hooks.py":
        sys.exit(98)
    (root / "eb.json").write_text(json.dumps({"argv": sys.argv[2:],
                                            "hooks": os.environ["EASYBUILD_HOOKS"],
                                            "umask": os.umask(0),
                                            "target": os.environ.get("EESSI_SOFTWARE_SUBDIR")}))
    sys.exit(int(os.environ.get("CONTROL_EB_STATUS", "0")))
'''
GUARD = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["CONTROL_ROOT"])
record = root / "load.json"
loaded = json.loads(record.read_text())
loaded["calls"].append(["eessi-arch-guard"] + sys.argv[1:])
record.write_text(json.dumps(loaded))
workdir = os.environ.get("EESSI_ARCH_GUARD_WORKDIR")
(root / "guard.json").write_text(json.dumps({
    "loaded_target": os.environ.get("EESSI_SOFTWARE_SUBDIR"),
    "workdir_mode": oct(os.stat(workdir).st_mode & 0o777) if workdir else None}))
status = int(os.environ.get("CONTROL_GUARD_STATUS", "0"))
if status == 0:
    print("export EESSI_SOFTWARE_SUBDIR=x86_64/intel/icelake")
sys.exit(status)
'''

class EnvironmentControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="controls-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.nodes = self.root / "node-mounts"
        self.job = self.nodes / (pwd.getpwuid(os.getuid()).pw_name + ".123")
        self.job.mkdir(parents=True)
        self.script = self.root / "eb-local"
        self.script.write_text(SCRIPT.read_text())
        self.config = self.root / "site.conf"
        self.config.write_text(f"node_local_root = {self.nodes}\n")
        self.config.chmod(0o600)
        (self.root / "doubles.sh").write_text(DOUBLE)
        (self.root / "capture.py").write_text(CAPTURE)
        self.prefix = self.root / "owned space 'quote' $(touch injected)"
        self.prefix.mkdir()
        # EESSI_ARCH_GUARD=0 keeps a guard installed on the test host off the doubles.
        self.env = dict(os.environ, BASH_ENV=str(self.root / "doubles.sh"),
                        CONTROL_ROOT=str(self.root), CONTROL_CLEAR=" ".join(CLEAR),
                        CONTROL_PREFIX=str(self.prefix), CONTROL_MODE="EESSI_USER_INSTALL",
                        EB_LOCAL_PREFIX=str(self.prefix), USER="fixture",
                        SLURM_JOB_ID="123", TMPDIR=str(self.job), CONTROL_JOB_ROOT=str(self.job),
                        EB_LOCAL_CONFIG=str(self.config), EESSI_ARCH_GUARD="0")
        self.env.update({name: "inherited" for name in CLEAR})

    def run_wrapper(self, arguments, umask=-1, **extra):
        argv, env = binary.command(self.script, arguments, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, text=True, capture_output=True, umask=umask)

    def check_build(self, mode, status=0):
        arguments = ["recipe with spaces.eb", "--robot", "--hooks=/private site/hooks.py",
                     "--include-easyblocks=/public helpers/package.py", "--rebuild"]
        if mode == "EESSI_PROJECT_INSTALL":
            prefix_args = ["--project", str(self.prefix)]
        else:
            prefix_args = []
        run = self.run_wrapper(prefix_args + arguments, umask=0o077, CONTROL_MODE=mode, CONTROL_EB_STATUS=str(status))
        self.assertEqual(run.returncode, status, run.stdout + run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        if mode == "EESSI_PROJECT_INSTALL":
            # EESSI-extend's umask for a project install (002) holds, for eb
            # and for the directories eb-local makes there, so that every
            # member can write them.
            self.assertEqual(built["argv"], arguments)
            self.assertEqual(built["umask"], 0o002)
            for sub in ("sources", "logs"):
                self.assertEqual((self.prefix / ".eb-local" / sub).stat().st_mode & 0o070, 0o070, sub)
        else:
            self.assertEqual(built["argv"], ["--umask=022"] + arguments)
            self.assertEqual(built["umask"], 0o077)
        self.check_loads(mode)

    def check_loads(self, mode):
        loaded = json.loads((self.root / "load.json").read_text())
        self.assertEqual(loaded["calls"], [["EESSI/2026.06"], ["EESSI-extend/2026.06-easybuild"]])
        self.assertEqual(loaded["env"], {mode: str(self.prefix)})

    def test_user_mode_clears_inherited_and_unload_restored_values(self):
        self.check_build("EESSI_USER_INSTALL")

    def test_project_mode_clears_inherited_and_unload_restored_values(self):
        self.check_build("EESSI_PROJECT_INSTALL")

    def test_eb_failure_exit_is_preserved(self):
        self.check_build("EESSI_USER_INSTALL", status=37)

    def check_environment(self, mode):
        arguments = ["--env"]
        if mode == "EESSI_PROJECT_INSTALL":
            arguments += ["--project", str(self.prefix)]
        run = self.run_wrapper(arguments, CONTROL_MODE=mode)
        self.assertEqual(run.returncode, 0, run.stderr)
        env_script = self.root / "selected-env.sh"
        env_script.write_text(run.stdout)
        replay = subprocess.run(["bash", "-c", 'source "$1"', "environment", str(env_script)],
                                env=dict(self.env, CONTROL_MODE=mode), cwd=self.root, text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        self.check_loads(mode)
        self.assertFalse((self.root / "injected").exists())

    def test_user_env_is_shell_safe_and_selects_only_user_mode(self):
        self.check_environment("EESSI_USER_INSTALL")

    def test_project_env_is_shell_safe_and_selects_only_project_mode(self):
        self.check_environment("EESSI_PROJECT_INSTALL")

    # -- eessi-arch-guard ----------------------------------------------------

    def with_guard(self):
        """An eessi-arch-guard double first on PATH."""
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(GUARD)
        guard.chmod(0o755)
        self.env["PATH"] = f"{bin_dir}:{self.env['PATH']}"

    def test_build_installs_for_the_target_the_arch_guard_selects(self):
        self.with_guard()
        run = self.run_wrapper(["recipe.eb"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        # The guard sees the target EESSI detected and runs before EESSI-extend
        # reads the install path from the stack.
        self.assertEqual(json.loads((self.root / "load.json").read_text())["calls"],
                         [["EESSI/2026.06"], ["eessi-arch-guard", "--strict", "--shell"],
                          ["EESSI-extend/2026.06-easybuild"]])
        guard = json.loads((self.root / "guard.json").read_text())
        self.assertEqual(guard["loaded_target"], "x86_64/amd/zen4")
        # --strict restores only in a workspace private to the user.
        self.assertEqual(guard["workdir_mode"], "0o700")
        self.assertEqual(json.loads((self.root / "eb.json").read_text())["target"], "x86_64/intel/icelake")
        self.assertIn("eb-local: target x86_64/intel/icelake,", run.stdout)

    def test_a_failed_arch_guard_stops_the_build(self):
        self.with_guard()
        run = self.run_wrapper(["recipe.eb"], CONTROL_GUARD_STATUS="78")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("eb-local: eessi-arch-guard could not select this node's target", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())
        self.assertEqual(json.loads((self.root / "load.json").read_text())["calls"],
                         [["EESSI/2026.06"], ["eessi-arch-guard", "--strict", "--shell"]])

    def test_env_runs_the_arch_guard_between_the_stack_and_the_extension(self):
        self.with_guard()
        run = self.run_wrapper(["env"])
        self.assertEqual(run.returncode, 0, run.stderr)
        env_script = self.root / "selected-env.sh"
        env_script.write_text(run.stdout)
        replay = subprocess.run(["bash", "-c", 'source "$1"; printf "%s\\n" "$EESSI_SOFTWARE_SUBDIR"',
                                 "environment", str(env_script)],
                                env=self.env, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        self.assertEqual(replay.stdout.splitlines()[-1], "x86_64/intel/icelake")
        self.assertEqual(json.loads((self.root / "load.json").read_text())["calls"],
                         [["EESSI/2026.06"], ["eessi-arch-guard", "--shell"],
                          ["EESSI-extend/2026.06-easybuild"]])

    def test_env_without_the_arch_guard_loads_the_stack_and_the_extension(self):
        run = self.run_wrapper(["env"], PATH="/usr/bin:/bin")
        self.assertEqual(run.returncode, 0, run.stderr)
        env_script = self.root / "selected-env.sh"
        env_script.write_text(run.stdout)
        replay = subprocess.run(["bash", "-c", 'source "$1"', "environment", str(env_script)],
                                env=dict(self.env, PATH=f"/usr/bin:/bin:{os.path.dirname(sys.executable)}"),
                                cwd=self.root, text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        self.check_loads("EESSI_USER_INSTALL")

    def test_project_directory_must_exist(self):
        run = self.run_wrapper(["--project", str(self.root / "absent"), "recipe.eb"])
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertFalse((self.root / "load.json").exists())

    @unittest.skipUnless(binary.BIN, "the project directory mode checks are a feature of the Zig build")
    def test_project_directory_mode(self):
        self.prefix.chmod(0o2770)
        run = self.run_wrapper(["env", "--project", str(self.prefix)], CONTROL_MODE="EESSI_PROJECT_INSTALL")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("setgid", run.stderr)
        self.prefix.chmod(0o770)
        run = self.run_wrapper(["env", "--project", str(self.prefix)], CONTROL_MODE="EESSI_PROJECT_INSTALL")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("chmod g+s", run.stderr)
        self.assertIn("export EESSI_PROJECT_INSTALL=", run.stdout)
        self.prefix.chmod(0o2777)
        run = self.run_wrapper(["env", "--project", str(self.prefix)], CONTROL_MODE="EESSI_PROJECT_INSTALL")
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertEqual(run.stdout, "")
        self.assertIn("writable by others", run.stderr)
        self.prefix.chmod(0o755)

    def test_allocation_is_required(self):
        env = dict(self.env)
        env.pop("SLURM_JOB_ID")
        argv, env = binary.command(SCRIPT, ["recipe.eb"], env)
        run = subprocess.run(argv, env=env, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertFalse((self.root / "load.json").exists())

if __name__ == "__main__":
    unittest.main()
