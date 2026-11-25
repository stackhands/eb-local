#!/usr/bin/env python3
"""OS `[Errno N]` stderr parity across check, dev, clean, build, and doctor."""
import os
from pathlib import Path
import re
import subprocess
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(
    binary.ZIG and os.geteuid() != 0,
    "errno stderr parity tests run unprivileged against the Zig binary",
)
class ErrnoStderrParity(StorageFixture):
    def run_bin(self, args, *, cwd=None, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=cwd or self.root, capture_output=True, text=True)

    def test_check_reports_posix_errno_for_missing_directory_and_unreadable_targets(self):
        missing = self.root / "no-such-binary"
        got_missing = self.run_bin(["check", str(missing)], SLURM_JOB_ID="")
        self.assertEqual(got_missing.returncode, 2, got_missing.stdout + got_missing.stderr)
        self.assertIn("[Errno 2] No such file or directory", got_missing.stderr)
        self.assertNotIn("(NotFound)", got_missing.stderr)

        subdir = self.root / "a-dir"
        subdir.mkdir()
        got_dir = self.run_bin(["check", str(subdir)], SLURM_JOB_ID="")
        self.assertEqual(got_dir.returncode, 2, got_dir.stdout + got_dir.stderr)
        self.assertIn("[Errno 21] Is a directory", got_dir.stderr)
        self.assertNotIn("(IsDir)", got_dir.stderr)

        secret_bin = self.root / "unreadable.so"
        secret_bin.write_bytes(b"\x7fELF")
        secret_bin.chmod(0o000)
        self.addCleanup(lambda: secret_bin.chmod(0o600))
        got_perm = self.run_bin(["check", str(secret_bin)], SLURM_JOB_ID="")
        self.assertEqual(got_perm.returncode, 2, got_perm.stdout + got_perm.stderr)
        self.assertIn("[Errno 13] Permission denied", got_perm.stderr)
        self.assertNotIn("(AccessDenied)", got_perm.stderr)

    def test_dev_envrc_and_lock_report_posix_errno_in_readonly_directory(self):
        ro = self.root / "readonly-cwd"
        ro.mkdir()
        ro.chmod(0o555)
        self.addCleanup(lambda: ro.chmod(0o755))

        envrc_got = self.run_bin(["dev", "--envrc"], cwd=ro, SLURM_JOB_ID="")
        self.assertEqual(envrc_got.returncode, 2, envrc_got.stdout + envrc_got.stderr)
        self.assertIn("[Errno 13] Permission denied", envrc_got.stderr)
        self.assertNotIn("(AccessDenied)", envrc_got.stderr)

        repo = self.root / "fake-eessi"
        init_file = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_file.parent.mkdir(parents=True)
        init_file.write_text(
            "export EESSI_VERSION=2026.06\n"
            "export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4\n"
            "module() { export LOADEDMODULES=EESSI/2026.06:demo/1.0; }\n",
            encoding="utf-8",
        )
        lock_got = self.run_bin(
            ["dev", "--lock", "demo/1.0"],
            cwd=ro,
            SLURM_JOB_ID="",
            EESSI_CVMFS_REPO=str(repo),
            BASH_ENV="",
        )
        self.assertEqual(lock_got.returncode, 2, lock_got.stdout + lock_got.stderr)
        self.assertIn("[Errno 13] Permission denied", lock_got.stderr)
        self.assertNotIn("(AccessDenied)", lock_got.stderr)

    def test_node_local_mount_and_doctor_workspace_report_posix_errno(self):
        self.nodes.chmod(0o000)
        self.addCleanup(lambda: self.nodes.chmod(0o755))
        build_got = self.run_bin(["recipe.eb"])
        self.assertEqual(build_got.returncode, 2, build_got.stdout + build_got.stderr)
        self.assertIn("[Errno 13] Permission denied", build_got.stderr)
        self.assertNotIn("(AccessDenied)", build_got.stderr)
        self.nodes.chmod(0o755)

        sealed = self.root / "sealed-parent"
        ws = sealed / "ws"
        ws.mkdir(parents=True)
        sealed.chmod(0o000)
        self.addCleanup(lambda: sealed.chmod(0o755))
        doc_got = self.run_bin(["doctor", "--workspace", str(ws)], SLURM_JOB_ID="")
        self.assertEqual(doc_got.returncode, 1, doc_got.stdout + doc_got.stderr)
        self.assertIn("[Errno 13] Permission denied", doc_got.stdout)
        self.assertNotIn("(AccessDenied)", doc_got.stdout)

    def test_clean_delete_reports_posix_errno_when_unlink_fails(self):
        src_dir = self.prefix / ".eb-local" / "sources" / "z"
        src_dir.mkdir(parents=True, exist_ok=True)
        tarball = src_dir / "zlib-1.3.tar.gz"
        tarball.write_text("archive\n", encoding="utf-8")
        src_dir.chmod(0o555)
        self.addCleanup(lambda: src_dir.chmod(0o755))

        clean_got = self.run_bin(
            ["clean", "--no-logs", "--sources", "--delete"],
            SLURM_JOB_ID="",
            PATH="/usr/bin:/bin",
        )
        self.assertEqual(clean_got.returncode, 1, clean_got.stdout + clean_got.stderr)
        self.assertIn("[Errno 13] Permission denied", clean_got.stderr)
        self.assertNotIn("(AccessDenied)", clean_got.stderr)

    def sources_to_clean(self):
        src_dir = self.prefix / ".eb-local" / "sources" / "z"
        src_dir.mkdir(parents=True, exist_ok=True)
        tarball = src_dir / "zlib-1.3.tar.gz"
        tarball.write_text("archive\n", encoding="utf-8")
        return src_dir, tarball

    def run_clean_sources(self, **extra):
        return self.run_bin(
            ["clean", "--no-logs", "--sources", "--delete"],
            SLURM_JOB_ID="",
            PATH="/usr/bin:/bin",
            **extra,
        )

    def test_failed_prefix_lock_release_after_clean_reports_errno_and_exits_one(self):
        _, tarball = self.sources_to_clean()
        got = self.run_clean_sources(EB_LOCAL_TEST_RELEASE_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertFalse(tarball.exists())
        lock = self.prefix / ".eb-local" / ".lock"
        self.assertIn(
            f"eb-local: cannot release the lock on {lock}: [Errno 5] Input/output error\n",
            got.stderr,
        )
        self.assertNotIn("(Unexpected)", got.stderr)

        _, tarball = self.sources_to_clean()
        clean = self.run_clean_sources()
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        self.assertNotIn("cannot release", clean.stderr)

    def test_failed_prefix_lock_release_after_a_failed_clean_keeps_the_first_errno(self):
        src_dir, _ = self.sources_to_clean()
        src_dir.chmod(0o555)
        self.addCleanup(lambda: src_dir.chmod(0o755))
        got = self.run_clean_sources(EB_LOCAL_TEST_RELEASE_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("[Errno 13] Permission denied", got.stderr)
        self.assertNotIn("cannot release", got.stderr)
        self.assertNotIn("[Errno 5]", got.stderr)

    def test_failed_prefix_lock_release_after_unwritable_clean_output_is_dropped(self):
        self.sources_to_clean()
        dry = self.run_bin(
            ["clean", "--no-logs", "--sources", "--delete", "--dry-run"],
            SLURM_JOB_ID="",
            PATH="/usr/bin:/bin",
        )
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        writes = len(dry.stdout.splitlines())
        lock = self.prefix / ".eb-local" / ".lock"
        # With every line written, the injected release failure is reported.
        _, tarball = self.sources_to_clean()
        control = self.run_clean_sources(EB_LOCAL_TEST_RELEASE_ERRNO="EIO", EB_LOCAL_TEST_STDOUT_WRITES=str(writes))
        self.assertEqual(control.returncode, 1, control.stdout + control.stderr)
        self.assertIn(f"eb-local: cannot release the lock on {lock}: [Errno 5]", control.stderr)
        self.assertNotIn("cannot write output", control.stderr)
        # With the last line unwritable, that failure is the only one.
        _, tarball = self.sources_to_clean()
        got = self.run_clean_sources(EB_LOCAL_TEST_RELEASE_ERRNO="EIO", EB_LOCAL_TEST_STDOUT_WRITES=str(writes - 1))
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertFalse(tarball.exists())
        self.assertIn("eb-local: cannot write output", got.stderr)
        self.assertNotIn("cannot release", got.stderr)

    def build_with_release_eio(self, **extra):
        got = self.run_bin(["recipe.eb"], EB_LOCAL_TEST_RELEASE_ERRNO="EIO", **extra)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("eb-local: what this runs:", got.stdout)
        self.assertEqual(got.stderr.count("eb-local: cannot "), 1, got.stderr)
        return got

    def test_failed_lock_releases_after_unwritable_build_output_are_dropped(self):
        # EB_LOCAL_KEEP_WORK keeps both locks until the end. The first write
        # is the "what this runs" line, the second the blank line before
        # "done", after the build.
        control = self.build_with_release_eio(EB_LOCAL_KEEP_WORK="1")
        self.assertIn("eb-local: done.", control.stdout)
        self.assertRegex(control.stderr, r"cannot release the lock on .*/\.eb-local\.lock: \[Errno 5\]")
        got = self.build_with_release_eio(EB_LOCAL_KEEP_WORK="1", EB_LOCAL_TEST_STDOUT_WRITES="1")
        self.assertNotIn("eb-local: done.", got.stdout)
        self.assertIn("eb-local: cannot write output", got.stderr)
        self.assertNotIn("cannot release", got.stderr)

    def test_failed_workspace_lock_release_after_unwritable_build_output_is_dropped(self):
        control = self.build_with_release_eio()
        self.assertIn("eb-local: done.", control.stdout)
        self.assertRegex(control.stderr, r"cannot release the lock on .*/eb-local\.[A-Za-z0-9]{8}/\.eb-local\.lock: \[Errno 5\]")
        # The workspace goes as after a build whose output was written; only
        # the failed write is reported, not the release after it.
        got = self.build_with_release_eio(EB_LOCAL_TEST_STDOUT_WRITES="1")
        self.assertNotIn("eb-local: done.", got.stdout)
        self.assertIn("eb-local: cannot write output", got.stderr)
        self.assertNotIn("cannot release", got.stderr)
        self.assertEqual([p.name for p in self.job.iterdir() if p.name.startswith("eb-local.")], [])

    def test_failed_workspace_lock_release_after_a_build_reports_errno_and_exits_one(self):
        got = self.run_bin(["recipe.eb"], EB_LOCAL_TEST_RELEASE_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertRegex(
            got.stderr,
            r"eb-local: cannot release the lock on " + re.escape(str(self.job))
            + r"/eb-local\.[A-Za-z0-9]{8}/\.eb-local\.lock: \[Errno 5\] Input/output error\n",
        )
        self.assertEqual(got.stderr.count("cannot release"), 1, got.stderr)

    def lmod_cache(self, spider_body, **extra):
        modules = self.root / "modules"
        modules.mkdir(exist_ok=True)
        spider = self.root / "spider"
        spider.write_text("#!/bin/sh\n" + spider_body, encoding="utf-8")
        spider.chmod(0o755)
        cache = self.root / "lmod-cache"
        got = self.run_bin(
            [
                "lmod-cache",
                "--modulepath", str(modules),
                "--cache-dir", str(cache),
                "--timestamp", str(self.root / "lmod-stamp"),
                "--spider", str(spider),
            ],
            SLURM_JOB_ID="",
            PATH="/usr/bin:/bin",
            **extra,
        )
        return cache, got

    def test_failed_directory_lock_release_after_lmod_cache_reports_errno_and_exits_one(self):
        cache, got = self.lmod_cache(
            "printf 'spiderT = {}\\n'\n", EB_LOCAL_TEST_RELEASE_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("wrote ", got.stdout)
        self.assertIn(
            f"eb-local: cannot release the lock on {cache}: [Errno 5] Input/output error\n",
            got.stderr,
        )
        self.assertEqual(got.stderr.count("cannot release"), 1, got.stderr)

    def test_failed_directory_lock_release_after_a_failed_spider_is_not_reported(self):
        _, got = self.lmod_cache("exit 3\n", EB_LOCAL_TEST_RELEASE_ERRNO="EIO")
        self.assertEqual(got.returncode, 3, got.stdout + got.stderr)
        self.assertIn("exited 3; the cache was not changed", got.stderr)
        self.assertNotIn("cannot release", got.stderr)


if __name__ == "__main__":
    unittest.main()
