#!/usr/bin/env python3
"""eb-local list and eb-local doctor, through the command line of the Zig build.

list reads the trees EESSI-extend makes, one per EESSI version and CPU
target; doctor reports what would stop a build or a module load.
"""
import os
from pathlib import Path
import subprocess
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(binary.BIN, "list and doctor are features of the Zig build")
class ListAndDoctor(StorageFixture):
    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def install(self, target, module):
        tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / target
        name, version = module.split("/")
        (tree / "software" / name / version).mkdir(parents=True, exist_ok=True)
        lua = tree / "modules" / "all" / name / f"{version}.lua"
        lua.parent.mkdir(parents=True, exist_ok=True)
        lua.write_text("-- module\n")

    def two_targets(self):
        self.install("x86_64/amd/zen2", "GSL/2.8-GCC-15.2.0")
        self.install("x86_64/amd/zen2", "pigz/2.8-GCCcore-15.2.0")
        self.install("x86_64/amd/zen4", "GSL/2.8-GCC-15.2.0")

    # -- list ---------------------------------------------------------------

    def test_list_shows_each_module_for_each_target(self):
        self.two_targets()
        run = self.run_tool(["list"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        lines = run.stdout.splitlines()
        self.assertIn("2 module(s) for 2 CPU target(s)", lines[0])
        self.assertEqual(lines[1].split(), ["MODULE", "zen2", "zen4"])
        self.assertEqual(lines[2].split(), ["GSL/2.8-GCC-15.2.0", "x", "x"])
        self.assertEqual(lines[3].split(), ["pigz/2.8-GCCcore-15.2.0", "x", "-"])
        self.assertIn("Load EESSI", lines[-1])

    def test_list_names_what_this_nodes_target_lacks(self):
        self.two_targets()
        run = self.run_tool(["list"], SLURM_JOB_ID="", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4", EESSI_VERSION="2026.06")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.splitlines()[1].split(), ["MODULE", "zen2", "zen4*"])
        self.assertIn("Not built for this node's target, x86_64/amd/zen4 (*): pigz/2.8-GCCcore-15.2.0.", run.stdout)
        run = self.run_tool(["list"], SLURM_JOB_ID="", EESSI_SOFTWARE_SUBDIR="x86_64/intel/icelake")
        self.assertIn("Nothing is built for this node's target, x86_64/intel/icelake", run.stdout)

    def test_list_narrows_to_names_and_versions(self):
        self.two_targets()
        for args in (["GSL"], ["GSL/2.8-GCC-15.2.0"]):
            with self.subTest(args=args):
                run = self.run_tool(["list"] + args, SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn("1 module(s)", run.stdout)
                self.assertNotIn("pigz", run.stdout)
        run = self.run_tool(["list", "GS"], SLURM_JOB_ID="")
        self.assertIn("Nothing that matches", run.stdout)
        self.assertEqual(self.run_tool(["list", "--all"], SLURM_JOB_ID="").returncode, 2)

    def test_list_of_an_empty_prefix_and_a_symlinked_tree(self):
        run = self.run_tool(["list"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("Nothing is installed", run.stdout)
        elsewhere = self.root / "elsewhere"
        self.prefix.mkdir(parents=True)
        (elsewhere / "versions").mkdir(parents=True)
        os.symlink(elsewhere / "versions", self.prefix / "versions")
        real = elsewhere / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen2"
        (real / "software").mkdir(parents=True)
        (real / "modules" / "all" / "x").mkdir(parents=True)
        (real / "modules" / "all" / "x" / "1.lua").write_text("")
        run = self.run_tool(["list"], SLURM_JOB_ID="")
        self.assertIn("Nothing is installed", run.stdout)

    # -- doctor -------------------------------------------------------------

    def test_doctor_in_a_good_allocation_finds_nothing_that_stops_a_build(self):
        run = self.run_tool(["doctor"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   Slurm job 123: build space {self.job}", run.stdout)
        self.assertIn("does not exist yet; the first build creates it", run.stdout)
        self.assertNotIn("FAIL", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))
        self.assertFalse(self.prefix.exists())

    def test_doctor_names_variables_left_in_the_shell(self):
        run = self.run_tool(["doctor"], EASYBUILD_INSTALLPATH="/elsewhere", LD_LIBRARY_PATH="/host/lib",
                            EESSI_USER_INSTALL=str(self.prefix))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn EASYBUILD_INSTALLPATH=/elsewhere is set in this shell", run.stdout)
        self.assertIn("warn LD_LIBRARY_PATH is set", run.stdout)
        self.assertIn("ok   EESSI_USER_INSTALL names your prefix", run.stdout)

    def test_doctor_fails_on_a_project_directory_others_can_write(self):
        project = self.root / "durable" / "project"
        project.mkdir(parents=True)
        project.chmod(0o2777)
        run = self.run_tool(["doctor", "--project", str(project)])
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL project directory", run.stdout)
        self.assertIn("writable by others", run.stdout)
        project.chmod(0o770)
        run = self.run_tool(["doctor", "--project", str(project)])
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("warn project directory", run.stdout)
        self.assertIn("chmod g+s", run.stdout)

    def test_doctor_outside_an_allocation_and_with_modules_off_modulepath(self):
        self.install("x86_64/amd/zen2", "GSL/2.8-GCC-15.2.0")
        run = self.run_tool(["doctor"], SLURM_JOB_ID="", MODULEPATH="/somewhere/else")
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("info not in a Slurm job", run.stdout)
        self.assertIn("warn your modules are not on MODULEPATH", run.stdout)
        inside = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen2" / "modules" / "all"
        run = self.run_tool(["doctor"], SLURM_JOB_ID="", MODULEPATH=f"/somewhere/else:{inside}")
        self.assertIn("ok   your modules are on MODULEPATH", run.stdout)
        self.assertEqual(self.run_tool(["doctor", "extra"]).returncode, 2)


if __name__ == "__main__":
    unittest.main()
