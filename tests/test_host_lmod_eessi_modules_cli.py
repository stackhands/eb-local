#!/usr/bin/env python3
"""A host Lmod whose MODULEPATH lacks EESSI's module directory.

A distribution's Lmod package defines `module` in every login shell, so
env, dev and a build use it, and source no init that would put EESSI's
modules on MODULEPATH. They add `<EESSI_CVMFS_REPO>/init/modules` when the
stack module is not on MODULEPATH there, and doctor says so.
"""
import json
import os
from pathlib import Path
import subprocess

from test_storage import StorageFixture

# Lmod as a distribution installs it: `module` finds a module only in a
# directory on MODULEPATH, and `use` puts one first.
HOST_LMOD = r'''
module() {
    local sub=$1 dir found name
    shift
    case $sub in
        is-avail|load)
            for name in "$@"; do
                found=
                IFS=: read -ra dirs <<< "${MODULEPATH-}"
                for dir in "${dirs[@]}"; do
                    [ -n "$dir" ] && [ -e "$dir/$name.lua" ] && found=$dir
                done
                if [ -z "$found" ]; then
                    [ "$sub" = load ] && echo "Lmod has detected the following error: The following module(s) are unknown: \"$name\"" >&2
                    return 1
                fi
            done
            [ "$sub" = is-avail ] && return 0
            [ "$sub" = load ] && [ -n "${CONTROL_ROOT-}" ] && python3 "$CONTROL_ROOT/capture.py" load "$@"
            export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4 EESSI_ACCELERATOR_TARGET= EESSI_VERSION=2026.06
            case $1 in
                EESSI-extend/*)
                    export EASYBUILD_INSTALLPATH="${EESSI_USER_INSTALL:-$HOME/eessi}/versions/2026.06/software/linux/x86_64/amd/zen4";;
            esac
            return 0;;
        use) export MODULEPATH="$1${MODULEPATH:+:$MODULEPATH}";;
        unload|purge) return 0;;
        *) return 99;;
    esac
}
eb() { python3 "$CONTROL_ROOT/capture.py" eb "$@"; }
export -f module eb
'''


class HostLmodEessiModules(StorageFixture):
    def setUp(self):
        super().setUp()
        self.repo = self.root / "repo"
        self.eessi_modules = self.repo / "init" / "modules"
        for name in ("EESSI/2026.06", "EESSI-extend/2026.06-easybuild"):
            module = self.eessi_modules / f"{name}.lua"
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_text("-- module\n")
        self.host_modules = self.root / "host-modulefiles"
        self.host_modules.mkdir()
        (self.root / "doubles.sh").write_text(HOST_LMOD)
        self.env.update(
            EESSI_CVMFS_REPO=str(self.repo),
            LMOD_CMD="/usr/share/lmod/lmod/libexec/lmod",
            MODULEPATH=str(self.host_modules),
        )

    def evaluate(self, lines, modulepath):
        """Run the lines as the caller's bash does, with the host Lmod's `module`."""
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.root),
            "EESSI_CVMFS_REPO": str(self.repo),
            "MODULEPATH": modulepath,
        }
        script = f'source {self.root / "doubles.sh"}\n{lines}\nprintf "%s\\n%s\\n" "$EESSI_SOFTWARE_SUBDIR" "$MODULEPATH"\n'
        return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", script],
                              env=env, cwd=self.root, capture_output=True, text=True)

    def test_env_lines_add_eessi_module_directory_for_a_host_lmod(self):
        lines = self.run_wrapper(["env"], SLURM_JOB_ID="")
        self.assertEqual(lines.returncode, 0, lines.stderr)
        run = self.evaluate(lines.stdout, str(self.host_modules))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        subdir, modulepath = run.stdout.splitlines()[-2:]
        self.assertEqual(subdir, "x86_64/amd/zen4")
        self.assertEqual(modulepath.split(":"), [str(self.eessi_modules), str(self.host_modules)])

    def test_env_lines_keep_a_modulepath_that_holds_the_stack(self):
        site = self.root / "site-modules"
        (site / "EESSI").mkdir(parents=True)
        (site / "EESSI" / "2026.06.lua").write_text("-- the site's own\n")
        lines = self.run_wrapper(["env"], SLURM_JOB_ID="")
        self.assertEqual(lines.returncode, 0, lines.stderr)
        run = self.evaluate(lines.stdout, f"{site}:{self.host_modules}")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.splitlines()[-1].split(":"), [str(site), str(self.host_modules)])

    def test_a_build_adds_eessi_module_directory_for_a_host_lmod(self):
        run = self.run_wrapper(["recipe.eb"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        loaded = json.loads((self.root / "load.json").read_text())
        self.assertEqual(loaded["argv"], ["EESSI-extend/2026.06-easybuild"])
        built = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(built["argv"], ["recipe.eb"])

    def test_doctor_says_eessi_module_directory_is_added(self):
        run = self.run_wrapper(["doctor"], SLURM_JOB_ID="")
        self.assertNotIn("FAIL", run.stdout)
        self.assertIn(f"info no directory on MODULEPATH in this shell holds stack.module, EESSI/2026.06 [default]; "
                      f"builds, env and dev add {self.eessi_modules}, which does\n", run.stdout)
        Path(self.eessi_modules / "EESSI" / "2026.06.lua").unlink()
        run = self.run_wrapper(["doctor"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL no directory on MODULEPATH in this shell holds stack.module", run.stdout)


if __name__ == "__main__":
    import unittest
    unittest.main()
