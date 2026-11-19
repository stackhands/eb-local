#!/usr/bin/env python3
"""A host whose only Lmod is EESSI's: a build, env and doctor, through the command line of the Zig build.

The shell eb-local runs in has no module command and the host has no Lmod
init. The fake EESSI init defines the module and eb doubles of
test_storage, as EESSI's init defines Lmod's module function; the eb
program on PATH runs that eb.
"""
from pathlib import Path
import shlex
import subprocess
import unittest

import binary
from test_storage import StorageFixture

EB = '#!/bin/bash\ndeclare -F eb >/dev/null || { echo "no eb double" >&2; exit 127; }\neb "$@"\n'


@unittest.skipUnless(binary.BIN, "the EESSI Lmod fallback is a feature of the Zig build")
class EessiLmod(StorageFixture):
    def setUp(self):
        super().setUp()
        if Path("/etc/profile.d/lmod.sh").exists():
            self.skipTest("/etc/profile.d/lmod.sh is this host's Lmod init, which comes before EESSI's")
        self.init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "eb").write_text(EB)
        (bin_dir / "eb").chmod(0o755)
        for name in [n for n in self.env if n.startswith("BASH_FUNC_")]:
            del self.env[name]
        for name in ("BASH_ENV", "LMOD_CMD", "MODULESHOME", "MODULEPATH", "EESSI_VERSION"):
            self.env.pop(name, None)
        self.env.update(PATH=f"{bin_dir}:/usr/bin:/bin", LMOD_PKG=str(self.root / "no-lmod"),
                        EESSI_CVMFS_REPO=str(self.root / "repo"))
        self.tried = f"{self.root}/no-lmod/init/bash, /etc/profile.d/lmod.sh or {self.init}"

    def eessi_init(self):
        self.init.parent.mkdir(parents=True)
        self.init.write_text(f"source {shlex.quote(str(self.root / 'doubles.sh'))}\necho 'EESSI init'\n")

    def test_a_build_sources_eessis_lmod_when_the_host_has_none(self):
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn(f"eb-local: no module command found; none of {self.tried} defined one\n", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())

        self.eessi_init()
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue((self.root / "eb.json").exists())
        self.assertNotIn("EESSI init", run.stdout)

    def test_env_in_a_shell_without_a_module_command_loads_eessi(self):
        self.eessi_init()
        run = self.run_wrapper(["env"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        shell = subprocess.run(["bash", "--noprofile", "--norc", "-c", run.stdout + 'printf %s "$EESSI_SOFTWARE_SUBDIR"'],
                               env=self.env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(shell.returncode, 0, shell.stderr)
        self.assertNotIn("command not found", shell.stderr)
        self.assertEqual(shell.stdout, "x86_64/amd/zen4")

    def test_doctor_names_the_init_a_build_sources_and_fails_without_one(self):
        run = self.run_wrapper(["doctor"])
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn(f"FAIL no module command in this shell, and none of {self.tried} can be read; builds stop there",
                      run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Something above says FAIL; builds stop there."), run.stdout)

        self.eessi_init()
        run = self.run_wrapper(["doctor"])
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn(f"info no module command in this shell; builds source {self.init}\n", run.stdout)
        self.assertNotIn("FAIL", run.stdout)

    def test_doctor_without_a_site_file_warns_that_env_and_dev_need_a_module_command(self):
        for installed in ("/etc/eb-local/config.toml", "/etc/eb-local.conf"):
            if Path(installed).exists():
                self.skipTest(f"{installed} is this host's site file")
        run = self.run_wrapper(["doctor"], EB_LOCAL_CONFIG="", XDG_CONFIG_HOME=str(self.root / "xdg"), SLURM_JOB_ID="")
        self.assertIn(f"warn no module command in this shell, and none of {self.tried} can be read", run.stdout)

    def test_directory_at_earlier_lmod_init_falls_through_to_eessi_init(self):
        self.eessi_init()
        dir_init = self.root / "no-lmod" / "init" / "bash"
        dir_init.mkdir(parents=True)

        doc = self.run_wrapper(["doctor"])
        self.assertEqual(doc.returncode, 0, doc.stdout + doc.stderr)
        self.assertIn(f"info no module command in this shell; builds source {self.init}\n", doc.stdout)
        self.assertNotIn(f"source {dir_init}", doc.stdout)

        env_run = self.run_wrapper(["env"], SLURM_JOB_ID="")
        self.assertEqual(env_run.returncode, 0, env_run.stderr)
        shell = subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", env_run.stdout + 'printf %s "$EESSI_SOFTWARE_SUBDIR"'],
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(shell.returncode, 0, shell.stderr)
        self.assertEqual(shell.stdout, "x86_64/amd/zen4")


if __name__ == "__main__":
    unittest.main()
