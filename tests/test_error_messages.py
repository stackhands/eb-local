#!/usr/bin/env python3
"""Error diagnostics name the target path and OS errno on filesystem failures."""

from pathlib import Path
import subprocess
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(binary.BIN, "diagnostic path and errno checks target the Zig build")
class ErrorPathAndErrno(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def test_clean_build_output_bytes_stay_unchanged(self):
        argv, env = binary.command(self.script, ["demo.eb"], dict(self.env))
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stderr, b"")
        self.assertIn(b"eb-local: done. To use the modules in a new shell or job:\n", run.stdout)

    def test_prefix_failures_name_path_and_errno(self):
        not_dir_parent = self.root / "regular-file"
        not_dir_parent.write_text("x\n")
        bad_child = not_dir_parent / "eessi"
        not_dir = self.run_wrapper(EB_LOCAL_PREFIX=str(bad_child))
        self.assertEqual(not_dir.returncode, 2, not_dir.stdout + not_dir.stderr)
        self.assertEqual(not_dir.stdout, "")
        self.assertIn(str(bad_child), not_dir.stderr)
        self.assertIn("[Errno 20] Not a directory", not_dir.stderr)

        ro_prefix = self.root / "ro-prefix"
        ro_prefix.mkdir()
        ro_prefix.chmod(0o555)
        try:
            ro = self.run_wrapper(EB_LOCAL_PREFIX=str(ro_prefix))
            self.assertEqual(ro.returncode, 2, ro.stdout + ro.stderr)
            self.assertEqual(ro.stdout, "")
            self.assertIn(str(ro_prefix), ro.stderr)
            self.assertIn("[Errno 13] Permission denied", ro.stderr)
        finally:
            ro_prefix.chmod(0o755)

    def test_mountinfo_failure_names_path_and_errno(self):
        missing_mi = self.root / "nonexistent-mountinfo"
        argv, env = binary.command(self.script, ["recipe.eb"], dict(self.env))
        env["EB_LOCAL_TEST_MOUNTINFO"] = str(missing_mi)
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn(str(missing_mi), run.stderr)
        self.assertIn("[Errno 2] No such file or directory", run.stderr)

    def test_durable_sources_failure_names_path_and_errno(self):
        meta = self.prefix / ".eb-local"
        meta.mkdir(parents=True)
        meta.chmod(0o555)
        try:
            run = self.run_wrapper()
            self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
            self.assertIn(str(meta / "sources"), run.stderr)
            self.assertIn("[Errno 13] Permission denied", run.stderr)
        finally:
            meta.chmod(0o755)

    def test_submit_write_failure_names_path_and_errno(self):
        site = self.root / "submit-site.toml"
        site.write_text(f'[storage]\nnode_local_root = "{self.nodes}"\n[build.node_types]\ncpu = "-p cpu"\n')
        site.chmod(0o644)
        fake_bin = self.root / "bin"
        fake_bin.mkdir(exist_ok=True)
        (fake_bin / "sbatch").write_text("#!/bin/sh\nexit 0\n")
        (fake_bin / "sbatch").chmod(0o755)
        jobs = self.prefix / ".eb-local" / "jobs"
        jobs.mkdir(parents=True)
        jobs.chmod(0o555)
        try:
            argv, env = binary.command(
                self.script,
                ["--config", str(site), "submit", "demo.eb"],
                dict(self.env, PATH=f"{fake_bin}:{self.env['PATH']}"),
            )
            run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
            self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
            self.assertIn(str(jobs), run.stderr)
            self.assertIn("[Errno 13] Permission denied", run.stderr)
        finally:
            jobs.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
