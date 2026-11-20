#!/usr/bin/env python3
"""Exercise the init lines that env and dev hand to the caller's shell."""
from pathlib import Path
import shutil
import subprocess
import unittest

import hostile_fs
from test_storage import StorageFixture

SOURCE_INIT = Path(__file__).resolve().parents[1] / "src" / "lmod-init.sh"


class CallerShellInit(StorageFixture):
    def setUp(self):
        super().setUp()
        if SOURCE_INIT.is_file():
            init_dir = self.root / "src"
            init_dir.mkdir()
            (init_dir / "lmod-init.sh").write_text(SOURCE_INIT.read_text())
        self.host_lmod = self.root / "lmod"
        self.eessi_lmod = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod"
        self.env.update(
            LMOD_PKG=str(self.host_lmod),
            EESSI_CVMFS_REPO=str(self.root / "repo"),
            EESSI_VERSION="2026.06",
        )

    def write_init_stubs(self, directory):
        directory.mkdir(parents=True)
        for shell in ("bash", "zsh"):
            (directory / shell).write_text(
                f"""printf '%s' {shell} >"$CONTROL_ROOT/init-used"
module() {{
    if [ "$1" = load ]; then
        export EESSI_VERSION=2026.06
        export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4
    fi
    return 0
}}
"""
            )

    def clean_env(self):
        env = dict(self.env)
        env.pop("BASH_ENV", None)
        for name in tuple(env):
            if name.startswith("BASH_FUNC_"):
                del env[name]
        return env

    def dev_lines(self):
        run = self.run_wrapper(["dev"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout

    def eval_in_clean_shell(self, shell, lines):
        marker = self.root / "init-used"
        marker.unlink(missing_ok=True)
        command = [
            shell,
            *(["--noprofile", "--norc"] if Path(shell).name == "bash" else ["-f"]),
            "-c",
            "typeset -f module >/dev/null 2>&1 && exit 97\n"
            + lines
            + '\ntypeset -f module >/dev/null\nprintf %s "$EESSI_SOFTWARE_SUBDIR"\n',
        ]
        run = subprocess.run(
            command,
            env=self.clean_env(),
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "x86_64/amd/zen4")
        return marker.read_text()

    def assert_shell_specific_init(self, directory):
        zsh = shutil.which("zsh")
        if zsh is None:
            self.skipTest("zsh is not installed")
        self.write_init_stubs(directory)
        lines = self.dev_lines()
        self.assertEqual(self.eval_in_clean_shell("/bin/bash", lines), "bash")
        self.assertEqual(self.eval_in_clean_shell(zsh, lines), "zsh")

    def test_clean_callers_source_their_lmod_initializer(self):
        self.assert_shell_specific_init(self.host_lmod / "init")

    def test_clean_callers_source_their_eessi_initializer(self):
        if not hostile_fs.enter_without_host_paths(self, ("/etc/profile.d/lmod.sh",)):
            return
        self.assert_shell_specific_init(self.eessi_lmod)


if __name__ == "__main__":
    unittest.main()
