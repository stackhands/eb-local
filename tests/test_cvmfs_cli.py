#!/usr/bin/env python3
"""doctor --cvmfs: the client probe, the proxy source, a stale mount, and an optional parallel read."""
import unittest

import binary
from test_storage import StorageFixture


def script(path, text):
    path.write_text(text)
    path.chmod(0o755)


@unittest.skipUnless(binary.BIN, "CernVM-FS checks are part of the Zig build")
class CvmfsDoctor(StorageFixture):
    def setUp(self):
        super().setUp()
        self.env["LMOD_CMD"] = "/usr/share/lmod/lmod/libexec/lmod"
        modules = self.root / "init" / "modules"
        (modules / "EESSI").mkdir(parents=True)
        (modules / "EESSI" / "2026.06.lua").write_text("-- module\n")
        self.env["MODULEPATH"] = str(modules)
        for name in ("CVMFS_HTTP_PROXY", "EESSI_CVMFS_REPO", "EB_LOCAL_DOCTOR_CVMFS_PARALLEL"):
            self.env.pop(name, None)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.host_path = self.env["PATH"]
        self.env["PATH"] = str(self.tools)
        self.cvmfs_etc = self.root / "cvmfs-etc"
        (self.cvmfs_etc / "config.d").mkdir(parents=True)
        (self.cvmfs_etc / "domain.d").mkdir()
        self.env["EB_LOCAL_TEST_CVMFS_CONFIG"] = str(self.cvmfs_etc)
        self.env["EB_LOCAL_TEST_CVMFS_ERRNO"] = "OK"
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.env["EESSI_CVMFS_REPO"] = str(self.repo)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return __import__("subprocess").run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_doctor_without_the_flag_does_not_check_the_client(self):
        run = self.run_tool(["doctor"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("CernVM-FS", run.stdout)
        explained = self.run_tool(["--explain", "recipe.eb"], PATH=self.host_path)
        self.assertEqual(explained.returncode, 0, explained.stderr)
        self.assertNotIn("cvmfs_config", explained.stdout)
        self.assertNotIn("CVMFS_HTTP_PROXY", explained.stdout)

    def test_probe_reports_the_proxy_file_and_a_host_injected_value(self):
        (self.cvmfs_etc / "default.local").write_text('CVMFS_HTTP_PROXY="http://old:3128"\n')
        (self.cvmfs_etc / "config.d" / f"{self.repo.name}.local").write_text("CVMFS_HTTP_PROXY=DIRECT\n")
        seen = self.root / "cvmfs-args"
        script(self.tools / "cvmfs_config", f"#!/bin/sh\nprintf '%s\\n' \"$@\" >> {seen}\nexit 0\n")
        run = self.run_tool(["doctor", "--cvmfs"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   CernVM-FS repository {self.repo} is mounted", run.stdout)
        self.assertIn(
            f"info CernVM-FS HTTP proxy mode is direct, from {self.cvmfs_etc}/config.d/{self.repo.name}.local",
            run.stdout)
        self.assertIn(f"ok   cvmfs_config probe {self.repo.name} exited 0", run.stdout)
        self.assertIn("ok   cvmfs_config chksetup exited 0", run.stdout)
        self.assertNotIn("parallel metadata", run.stdout)
        self.assertEqual(seen.read_text().splitlines(), ["probe", self.repo.name, "chksetup"])

        injected = self.run_tool(["doctor", "--cvmfs"], CVMFS_HTTP_PROXY="http://host:3128")
        self.assertIn(
            "warn CernVM-FS HTTP proxy http://host:3128, from environment CVMFS_HTTP_PROXY; a host can inject this",
            injected.stdout)

        script(self.tools / "cvmfs_config", "#!/bin/sh\nexit 1\n")
        failed = self.run_tool(["doctor", "--cvmfs"])
        self.assertEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertIn(f"warn cvmfs_config probe {self.repo.name} exited 1", failed.stdout)
        self.assertIn("warn cvmfs_config chksetup exited 1", failed.stdout)

    def test_a_stale_mount_fails_and_skips_the_probe(self):
        seen = self.root / "cvmfs-args"
        script(self.tools / "cvmfs_config", f"#!/bin/sh\nprintf '%s\\n' \"$@\" >> {seen}\nexit 0\n")
        run = self.run_tool(["doctor", "--cvmfs"], EB_LOCAL_TEST_CVMFS_ERRNO="ENOTCONN")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn(f"FAIL CernVM-FS repository {self.repo} is a stale FUSE mount: transport endpoint is not connected", run.stdout)
        self.assertIn("info cvmfs_config probe was not run; the mount is stale", run.stdout)
        self.assertIn("ok   cvmfs_config chksetup exited 0", run.stdout)
        self.assertEqual(seen.read_text().split(), ["chksetup"])
        self.assertIn("Something above says FAIL", run.stdout)

        missing = self.run_tool(["doctor", "--cvmfs"], EB_LOCAL_TEST_CVMFS_ERRNO="ABSENT")
        self.assertEqual(missing.returncode, 0, missing.stdout + missing.stderr)
        self.assertIn(f"info CernVM-FS repository {self.repo} is not mounted", missing.stdout)

        broken = self.run_tool(["doctor", "--cvmfs"], EB_LOCAL_TEST_CVMFS_ERRNO="EIO")
        self.assertEqual(broken.returncode, 0, broken.stdout + broken.stderr)
        self.assertIn(f"warn CernVM-FS repository {self.repo} returned an input/output error", broken.stdout)

    def test_without_cvmfs_config_the_check_says_so(self):
        run = self.run_tool(["doctor", "--cvmfs"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("info cvmfs_config is not on PATH, so probe and chksetup were not run", run.stdout)
        self.assertIn("info CernVM-FS HTTP proxy is unset", run.stdout)

    def test_parallel_read_uses_srun_inside_an_allocation_and_waits_outside(self):
        seen = self.root / "srun-args"
        script(self.tools / "srun", f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {seen}\nexit 0\n")
        run = self.run_tool(["doctor", "--cvmfs-parallel", "2"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   srun -n 2 read metadata of {self.repo}", run.stdout)
        recorded = seen.read_text().splitlines()
        self.assertEqual(recorded[:3], ["-n", "2", "stat"])
        self.assertEqual(recorded[3], str(self.repo))

        self.env.pop("SLURM_JOB_ID", None)
        outside = self.run_tool(["doctor", "--cvmfs-parallel=3"])
        self.assertEqual(outside.returncode, 0, outside.stdout + outside.stderr)
        self.assertIn("info parallel metadata read of 3 tasks runs only inside an allocation", outside.stdout)

    def test_without_srun_an_allocation_reads_from_this_process(self):
        run = self.run_tool(["doctor", "--cvmfs"], EB_LOCAL_DOCTOR_CVMFS_PARALLEL="2")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   parallel metadata read of 2 tasks on {self.repo}", run.stdout)

    def test_the_count_alone_does_not_turn_the_check_on(self):
        run = self.run_tool(["doctor"], EB_LOCAL_DOCTOR_CVMFS_PARALLEL="2")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("CernVM-FS", run.stdout)
        refused = self.run_tool(["doctor", "--cvmfs-parallel", "9"])
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("1 to 8", refused.stderr)
        shown = self.run_tool(["config"])
        self.assertRegex(shown.stdout, r"doctor\.cvmfs_parallel\s+0\s+\[default\]")
        exported = self.run_tool(["config", "--env"])
        self.assertIn("export EB_LOCAL_DOCTOR_CVMFS_PARALLEL=0\n", exported.stdout)
