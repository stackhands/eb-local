#!/usr/bin/env python3
"""eb-local list and eb-local doctor, through the command line of the Zig build.

list reads the trees EESSI-extend makes, one per EESSI version and CPU
target; doctor reports what would stop a build or a module load.
"""
import os
from pathlib import Path
import re
import subprocess
import unittest

import binary
from test_storage import StorageFixture

README = Path(__file__).resolve().parents[1] / "README.md"

# eessi-arch-guard --strict --shell: a reload, a guard that keeps the
# target, or one that cannot select a target.
GUARD = r'''#!/bin/sh
printf '%s\n' "$*" > "$CONTROL_ROOT/guard-args"
printf '%s\n' "$EESSI_ARCH_GUARD_WORKDIR" > "$CONTROL_ROOT/guard-workdir"
stat -c %a "$EESSI_ARCH_GUARD_WORKDIR" > "$CONTROL_ROOT/guard-workdir-mode"
case "${GUARD_DOUBLE:-reload}" in
    reload) echo "export EESSI_ARCH_GUARD_RELOADED='x86_64/amd/zen4->x86_64/amd/zen2'"
            echo "export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen2" ;;
    keep) ;;
    fail) echo "eessi-arch-guard: no software directory for x86_64/amd/zen4" >&2; exit 78 ;;
esac
'''


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

    def test_the_readme_default_for_a_site_is_one_prefix_for_eb_local_and_eessi_extend(self):
        text = README.read_text()
        section = text[text.index("\n## A site Lmod hook\n"):]
        line = re.search(r"```toml\n(prefix = .*)\n```", section).group(1)
        home = self.root / "home"
        home.mkdir()
        site = self.root / "site.toml"
        site.write_text(f'{line}\n\n[storage]\nnode_local_root = "{self.nodes}"\nnode_local_fstype = "xfs"\n'
                        'shared_scratch = ["/scratch"]\n')
        site.chmod(0o644)
        del self.env["EB_LOCAL_PREFIX"]
        run = self.run_tool(["doctor"], HOME=str(home), EB_LOCAL_CONFIG=str(site),
                            EESSI_USER_INSTALL=str(home / ".local" / "eessi"))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   installs go to {home}/.local/eessi: a user install, prefix from site {site}:1\n", run.stdout)
        self.assertIn("ok   EESSI_USER_INSTALL names your prefix", run.stdout)
        self.assertNotIn("warn EESSI_USER_INSTALL", run.stdout)

    def guard_path(self):
        bin = self.root / "guard-bin"
        bin.mkdir()
        (bin / "eessi-arch-guard").write_text(GUARD)
        (bin / "eessi-arch-guard").chmod(0o755)
        return f"{bin}:/usr/bin:/bin"

    def test_doctor_shows_the_target_eessi_arch_guard_selects_in_a_job(self):
        loaded = dict(EESSI_ARCH_GUARD="", PATH=self.guard_path(), EESSI_VERSION="2026.06",
                      EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        run = self.run_tool(["doctor"], **loaded)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("ok   eessi-arch-guard selects x86_64/amd/zen2 here, not x86_64/amd/zen4, which EESSI is"
                      " loaded for; builds, env and dev use x86_64/amd/zen2\n", run.stdout)
        # Asked as a build asks it, with a private directory of its own.
        self.assertEqual((self.root / "guard-args").read_text(), "--strict --shell\n")
        self.assertEqual((self.root / "guard-workdir-mode").read_text(), "700\n")
        workdir = Path((self.root / "guard-workdir").read_text().strip())
        self.assertEqual(workdir.parent, self.job)
        self.assertFalse(workdir.exists())
        self.assertEqual(list(self.job.iterdir()), [])
        run = self.run_tool(["doctor"], GUARD_DOUBLE="keep", **loaded)
        self.assertIn("ok   eessi-arch-guard selects x86_64/amd/zen4, the target EESSI is loaded for\n", run.stdout)
        run = self.run_tool(["doctor"], GUARD_DOUBLE="fail", **loaded)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn eessi-arch-guard cannot select a target here (exit 78: eessi-arch-guard: no software"
                      " directory for x86_64/amd/zen4); builds stop when it cannot, and EESSI_ARCH_GUARD=0 turns it off\n",
                      run.stdout)

    def test_doctor_asks_eessi_arch_guard_only_in_a_job_with_eessi_loaded(self):
        on_path = dict(EESSI_ARCH_GUARD="", PATH=self.guard_path(), EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        for outside in (dict(SLURM_JOB_ID=""), dict(EESSI_SOFTWARE_SUBDIR="")):
            run = self.run_tool(["doctor"], **dict(on_path, **outside))
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("info eessi-arch-guard is on PATH; builds, env and dev load EESSI for the target it selects,"
                          " which doctor shows inside a job with EESSI loaded\n", run.stdout)
        run = self.run_tool(["doctor"], **dict(on_path, EESSI_ARCH_GUARD="0"))
        self.assertIn("info eessi-arch-guard is on PATH, and EESSI_ARCH_GUARD=0 turns it off\n", run.stdout)
        self.assertFalse((self.root / "guard-args").exists())
        run = self.run_tool(["doctor"], EESSI_ARCH_GUARD="", PATH="/usr/bin:/bin")
        self.assertIn("info eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI"
                      " detects\n", run.stdout)

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

    def test_doctor_fails_on_a_secret_every_build_would_stop_on(self):
        secret = dict(EB_LOCAL_SECRET_MY_LICENCE_KEY="env:MY_LICENCE_SRC")
        run = self.run_tool(["doctor"], **secret)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL secret MY_LICENCE_KEY: MY_LICENCE_SRC is not set", run.stdout)
        self.assertIn("every build stops there, whether or not it uses MY_LICENCE_KEY", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Something above says FAIL; builds stop there."))
        build = self.run_wrapper(["recipe.eb"], **secret)
        self.assertEqual(build.returncode, 2, build.stdout + build.stderr)
        self.assertIn("MY_LICENCE_SRC is not set", build.stderr)

        value = "licence-value-27000"
        run = self.run_tool(["doctor"], MY_LICENCE_SRC=value, **secret)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("ok   secret MY_LICENCE_KEY can be read from env:MY_LICENCE_SRC", run.stdout)
        self.assertNotIn(value, run.stdout + run.stderr)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))
        run = self.run_tool(["doctor"], MY_LICENCE_SRC="x7q", **secret)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("warn secret MY_LICENCE_KEY from env:MY_LICENCE_SRC is shorter than 4 bytes", run.stdout)
        self.assertNotIn("x7q", run.stdout + run.stderr)

        run = self.without_a_site_file(**secret)
        self.assertIn("warn secret MY_LICENCE_KEY: MY_LICENCE_SRC is not set", run.stdout)

    def without_a_site_file(self, **extra):
        for installed in ("/etc/eb-local/config.toml", "/etc/eb-local.conf"):
            if Path(installed).exists():
                self.skipTest(f"{installed} is this host's site file")
        repo = self.root / "repo"
        return self.run_tool(["doctor"], EB_LOCAL_CONFIG="", XDG_CONFIG_HOME=str(self.root / "xdg"),
                             SLURM_JOB_ID="", EESSI_CVMFS_REPO=str(repo), **extra)

    def test_doctor_without_a_site_file_judges_eb_local_eb(self):
        init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        run = self.without_a_site_file()
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("info no site file sets storage.node_local_root: `eb-local RECIPE` needs a site file; "
                      "`eb-local eb` does not.", run.stdout)
        self.assertIn(f"FAIL {init} is missing, so `eb-local eb` stops", run.stdout)
        self.assertEqual(run.stdout.count("FAIL"), 2, run.stdout)

        init.parent.mkdir(parents=True)
        init.write_text("")
        run = self.without_a_site_file()
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertNotIn("FAIL", run.stdout)
        self.assertIn(f"ok   `eb-local eb` sources {init}", run.stdout)
        self.assertIn("ok   `eb-local eb` makes a user install into the module's default, $HOME/eessi", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith(
            "Nothing above stops `eb-local eb`; `eb-local RECIPE` needs a site file."), run.stdout)

        run = self.without_a_site_file(EESSI_PROJECT_INSTALL="/project/climate")
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("ok   `eb-local eb` makes a project install: EESSI_PROJECT_INSTALL=/project/climate", run.stdout)

        run = self.without_a_site_file(EESSI_USER_INSTALL="/home/alice/eessi", EESSI_SITE_INSTALL="")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL more than one of EESSI_USER_INSTALL", run.stdout)
        self.assertIn("so `eb-local eb` refuses to run", run.stdout)

    def test_doctor_with_a_site_file_judges_builds_and_warns_for_eb_local_eb(self):
        run = self.run_tool(["doctor"], EESSI_CVMFS_REPO=str(self.root / "repo"),
                            EESSI_USER_INSTALL=str(self.prefix), EESSI_SITE_INSTALL="")
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertNotIn("FAIL", run.stdout)
        self.assertIn("is missing, so `eb-local eb` stops", run.stdout)
        self.assertIn("warn more than one of EESSI_USER_INSTALL", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))


if __name__ == "__main__":
    unittest.main()
