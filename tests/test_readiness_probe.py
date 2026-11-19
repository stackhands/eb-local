#!/usr/bin/env python3
"""The standalone EESSI readiness probe."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "eb-local-readiness"


class ReadinessProbeTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="eb-local-readiness-")
        self.root = Path(self.work.name)
        self.repo = self.root / "eessi"
        self.local = self.root / "local"
        self.upstream_modules = self.repo / "init" / "modules"
        self.local_modules = self.local / "versions" / "2026.06" / "modules" / "all"
        self.upstream_modules.mkdir(parents=True)
        self.local_modules.mkdir(parents=True)
        self.mountinfo = self.root / "mountinfo"

    def tearDown(self):
        self.work.cleanup()

    def run_probe(self, modulepath, fstype="cvmfs"):
        self.mountinfo.write_text(
            "81 1 0:81 / {} rw,relatime - {} source rw\n".format(self.repo, fstype)
        )
        env = dict(os.environ, MODULEPATH=modulepath)
        return subprocess.run(
            [
                str(PROBE),
                "--repo",
                str(self.repo),
                "--prefix",
                str(self.local),
                "--mountinfo",
                str(self.mountinfo),
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_ready_client_and_module_order(self):
        run = self.run_probe("{}:{}".format(self.local_modules, self.upstream_modules))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("mounted with cvmfs", run.stdout)
        self.assertIn("ok   local modules precede EESSI", run.stdout)

    def test_upstream_modules_first_is_a_failure(self):
        run = self.run_probe("{}:{}".format(self.upstream_modules, self.local_modules))
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("FAIL EESSI precedes local modules", run.stdout)

    def test_a_site_bind_mount_is_a_warning(self):
        run = self.run_probe(
            "{}:{}".format(self.local_modules, self.upstream_modules), fstype="ext4"
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn EESSI repository", run.stdout)
        self.assertIn("site bind mount", run.stdout)

    def test_empty_prefix_or_repo_is_refused(self):
        for flag in ("--prefix", "--repo"):
            self.mountinfo.write_text(
                "81 1 0:81 / {} rw,relatime - cvmfs source rw\n".format(self.repo)
            )
            run = subprocess.run(
                [
                    str(PROBE),
                    "--repo",
                    str(self.repo),
                    "--mountinfo",
                    str(self.mountinfo),
                    flag,
                    "",
                ],
                env=dict(os.environ, MODULEPATH=str(self.upstream_modules)),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
            self.assertIn("must not be empty", run.stderr)

    def test_stacked_cvmfs_mount_over_autofs_at_same_path(self):
        self.mountinfo.write_text(
            "80 1 0:80 / {repo} rw,relatime - autofs systemd-1 rw\n"
            "81 80 0:81 / {repo} rw,relatime - cvmfs cvmfs2 rw\n".format(repo=self.repo)
        )
        run = subprocess.run(
            [
                str(PROBE),
                "--repo",
                str(self.repo),
                "--prefix",
                str(self.local),
                "--mountinfo",
                str(self.mountinfo),
            ],
            env=dict(
                os.environ,
                MODULEPATH="{}:{}".format(self.local_modules, self.upstream_modules),
            ),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("mounted with cvmfs", run.stdout)
        self.assertNotIn("autofs", run.stdout)

    def test_symlinked_prefix_and_repo_match_real_modulepath(self):
        sym_local = self.root / "local-link"
        sym_repo = self.root / "eessi-link"
        sym_local.symlink_to(self.local)
        sym_repo.symlink_to(self.repo)
        self.mountinfo.write_text(
            "81 1 0:81 / {} rw,relatime - cvmfs source rw\n".format(self.repo)
        )
        run = subprocess.run(
            [
                str(PROBE),
                "--repo",
                str(sym_repo),
                "--prefix",
                str(sym_local),
                "--mountinfo",
                str(self.mountinfo),
            ],
            env=dict(
                os.environ,
                MODULEPATH="{}:{}".format(self.local_modules, self.upstream_modules),
            ),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("mounted with cvmfs", run.stdout)
        self.assertIn("ok   local modules precede EESSI", run.stdout)


    def test_shorter_real_mount_covers_earlier_longer_symlink_mount(self):
        alias_dir = self.root / "longer-symlink-alias"
        alias_dir.symlink_to(self.repo)
        self.mountinfo.write_text(
            "80 1 0:80 / {alias} rw,relatime - autofs systemd-1 rw\n"
            "81 80 0:81 / {real} rw,relatime - cvmfs cvmfs2 rw\n".format(
                alias=alias_dir, real=self.repo
            )
        )
        run = subprocess.run(
            [
                str(PROBE),
                "--repo",
                str(self.repo),
                "--prefix",
                str(self.local),
                "--mountinfo",
                str(self.mountinfo),
            ],
            env=dict(
                os.environ,
                MODULEPATH="{}:{}".format(self.local_modules, self.upstream_modules),
            ),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("mounted with cvmfs", run.stdout)
        self.assertNotIn("autofs", run.stdout)


    def test_empty_eessi_cvmfs_repo_env_uses_default_repo(self):
        self.mountinfo.write_text("")
        env = dict(os.environ, EESSI_CVMFS_REPO="", EB_LOCAL_PREFIX="", MODULEPATH="")
        run = subprocess.run(
            [str(PROBE), "--mountinfo", str(self.mountinfo)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(run.stderr, "")
        self.assertIn("/cvmfs/software.eessi.io", run.stdout)

    def test_non_utf8_and_fifo_mountinfo_fail_cleanly(self):
        bad_utf8 = self.root / "bad-utf8-mountinfo"
        bad_utf8.write_bytes(b"22 1 0:21 / / rw - ext4 /dev/sda1 rw\n# \xff\n")
        run_utf8 = subprocess.run(
            [str(PROBE), "--repo", str(self.repo), "--mountinfo", str(bad_utf8)],
            env=dict(os.environ, EB_LOCAL_PREFIX="", MODULEPATH=""),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(run_utf8.returncode, 1, run_utf8.stdout + run_utf8.stderr)
        self.assertNotIn("Traceback", run_utf8.stderr)
        self.assertIn(f"FAIL cannot read {bad_utf8}:", run_utf8.stderr)

        fifo = self.root / "fifo-mountinfo"
        os.mkfifo(fifo)
        run_fifo = subprocess.run(
            [str(PROBE), "--repo", str(self.repo), "--mountinfo", str(fifo)],
            env=dict(os.environ, EB_LOCAL_PREFIX="", MODULEPATH=""),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(run_fifo.returncode, 1, run_fifo.stdout + run_fifo.stderr)
        self.assertIn(f"FAIL cannot read {fifo}: not a regular file", run_fifo.stderr)

if __name__ == "__main__":
    unittest.main()
