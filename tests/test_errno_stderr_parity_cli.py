#!/usr/bin/env python3
"""OS `[Errno N]` stderr parity across check, dev, clean, build, and doctor."""
import os
from pathlib import Path
import subprocess
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(
    binary.BIN and os.geteuid() != 0,
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


if __name__ == "__main__":
    unittest.main()
