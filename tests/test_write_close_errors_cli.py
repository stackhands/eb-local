#!/usr/bin/env python3
"""A failed close or fsync of a file eb-local writes is an error.

NFS and some quota setups report a lost write only when the file is closed
or synced. The test artifact reads EB_LOCAL_TEST_CLOSE_ERRNO and
EB_LOCAL_TEST_FSYNC_ERRNO, and the close or fsync of each written file then
fails with that errno. Each case runs the command once without the errno,
which must succeed, and once with it, which must report the errno and must
not say that the file was written.
"""
import os
import subprocess
import unittest

import binary
from test_storage import StorageFixture

EIO_TEXT = "[Errno 5] Input/output error"


@unittest.skipUnless(
    binary.ZIG and os.geteuid() != 0,
    "the close and fsync errno hooks are in the Zig test artifact",
)
class WriteCloseErrors(StorageFixture):
    def run_bin(self, args, *, cwd=None, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=cwd or self.root, capture_output=True, text=True)

    def fresh_dir(self, name):
        path = self.root / name
        path.mkdir()
        return path

    def fake_eessi(self):
        repo = self.root / "fake-eessi"
        init_file = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_file.parent.mkdir(parents=True)
        init_file.write_text(
            "export EESSI_VERSION=2026.06\n"
            "export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4\n"
            "module() { export LOADEDMODULES=EESSI/2026.06:demo/1.0; }\n",
            encoding="utf-8",
        )
        return repo

    def test_dev_envrc_reports_a_failed_close_of_a_new_envrc(self):
        control = self.fresh_dir("envrc-control")
        ok = self.run_bin(["dev", "--envrc"], cwd=control, SLURM_JOB_ID="")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("wrote .envrc", ok.stderr)

        cwd = self.fresh_dir("envrc-close")
        got = self.run_bin(["dev", "--envrc"], cwd=cwd, SLURM_JOB_ID="", EB_LOCAL_TEST_CLOSE_ERRNO="EIO")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn(f"eb-local: cannot write .envrc ({EIO_TEXT})", got.stderr)
        self.assertNotIn("wrote .envrc", got.stderr)

    def test_dev_lock_reports_a_failed_close_of_a_new_lock_file(self):
        repo = self.fake_eessi()
        extra = dict(SLURM_JOB_ID="", EESSI_CVMFS_REPO=str(repo), BASH_ENV="")
        control = self.fresh_dir("lock-control")
        ok = self.run_bin(["dev", "--lock", "demo/1.0"], cwd=control, **extra)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertTrue((control / "eb-local.lock").is_file())

        cwd = self.fresh_dir("lock-close")
        got = self.run_bin(["dev", "--lock", "demo/1.0"], cwd=cwd, EB_LOCAL_TEST_CLOSE_ERRNO="EIO", **extra)
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn(f"eb-local: cannot write eb-local.lock ({EIO_TEXT})", got.stderr)

    def test_doctor_workspace_fails_the_probe_when_its_close_fails(self):
        ws = self.fresh_dir("probe-ws")
        ok = self.run_bin(["doctor", "--workspace", str(ws)], SLURM_JOB_ID="")
        self.assertIn("created, wrote, renamed, executed and removed a probe", ok.stdout)

        got = self.run_bin(["doctor", "--workspace", str(ws)], SLURM_JOB_ID="", EB_LOCAL_TEST_CLOSE_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn(f"workspace {ws} probe could not complete ({EIO_TEXT})", got.stdout)
        self.assertNotIn("created, wrote, renamed", got.stdout)
        self.assertEqual(list(ws.iterdir()), [])

    def workstation_build(self, **extra):
        self.config.write_text("# workstation: no node-local root\n")
        cache = self.root / "cache"
        return self.run_wrapper(SLURM_JOB_ID="", TMPDIR="", XDG_CACHE_HOME=str(cache), **extra)

    def test_workstation_build_stops_when_the_workspace_root_record_is_not_durable(self):
        ok = self.workstation_build()
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        (self.root / "eb.json").unlink()

        for hook in ("EB_LOCAL_TEST_FSYNC_ERRNO", "EB_LOCAL_TEST_CLOSE_ERRNO"):
            with self.subTest(hook=hook):
                got = self.workstation_build(**{hook: "EIO"})
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertIn("eb-local: cannot record workstation workspace root ", got.stderr)
                self.assertIn(f"({EIO_TEXT})", got.stderr)
                self.assertFalse((self.root / "eb.json").exists())

    def lmod_cache(self, name, **extra):
        modules = self.root / "modules"
        modules.mkdir(exist_ok=True)
        spider = self.root / "spider"
        spider.write_text("#!/bin/sh\nprintf 'spiderT = {}\\n'\n", encoding="utf-8")
        spider.chmod(0o755)
        cache = self.root / name
        stamp = self.root / f"{name}-stamp"
        got = self.run_bin(
            [
                "lmod-cache",
                "--modulepath", str(modules),
                "--cache-dir", str(cache),
                "--timestamp", str(stamp),
                "--spider", str(spider),
            ],
            SLURM_JOB_ID="",
            PATH="/usr/bin:/bin",
            **extra,
        )
        return cache, stamp, got

    def test_lmod_cache_fails_when_the_timestamp_directory_is_not_synced(self):
        _, _, ok = self.lmod_cache("control-cache")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("wrote ", ok.stdout)

        cache, stamp, got = self.lmod_cache("fsync-cache", EB_LOCAL_TEST_FSYNC_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn(f"eb-local: cannot write {stamp}: {EIO_TEXT}\n", got.stderr)
        self.assertNotIn("wrote ", got.stdout)
        self.assertFalse((cache / "spiderT.lua").exists())


if __name__ == "__main__":
    unittest.main()
