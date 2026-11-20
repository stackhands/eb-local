"""CLI regression tests for atomic cleanup when `dev --envrc` or `dev --lock` fails mid-write."""

import os
import resource
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary


def _limit_fsize_32() -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (32, 32))


def _limit_fsize_32_sigign() -> None:
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (32, 32))


def _limit_fsize_lock() -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (3800, 3800))


class DevWriteFailureCleanupCli(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.prefix = self.root / "prefix"
        self.site = self.root / "site.toml"
        self.site.write_text('[storage]\nnode_local_root = "/local"\n', encoding="utf-8")
        self.site.chmod(0o600)
        self.work = self.root / "work"
        self.work.mkdir()

    def _run_dev(self, args: list[str], preexec_fn=None, **extra_env: str) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": str(self.site),
            "EB_LOCAL_PREFIX": str(self.prefix),
            **extra_env,
        }
        return subprocess.run(
            [binary.BIN, "dev", *args],
            cwd=self.work,
            env=env,
            preexec_fn=preexec_fn,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_new_envrc_write_failure_exits_cleanly_without_partial_or_temp_files(self):
        for label, preexec in (("sigdfl", _limit_fsize_32), ("sigign", _limit_fsize_32_sigign)):
            with self.subTest(mode=label):
                for child in list(self.work.iterdir()):
                    child.unlink()
                res = self._run_dev(["--envrc", "FFTW/3.3.10-GCC-15.2.0"], preexec_fn=preexec)
                self.assertGreater(
                    res.returncode,
                    0,
                    f"expected clean non-signal error exit ({label}), got rc={res.returncode}: {res.stderr!r}",
                )
                self.assertIn("cannot write .envrc", res.stderr)
                leftover = sorted(p.name for p in self.work.iterdir())
                self.assertEqual(leftover, [], f"unexpected partial or temp files left in cwd ({label}): {leftover}")

    def test_existing_envrc_and_new_or_existing_lock_survive_write_failure_cleanly(self):
        # 500 short module names take ~3000 bytes in `env -0` (< 3800) and > 4100 bytes as JSON (> 3800).
        resolved = {
            "LOADEDMODULES": ":".join(f"a/{i:03d}" for i in range(500)),
            "EESSI_SOFTWARE_SUBDIR": "x86_64/amd/zen4",
            "EESSI_VERSION": "2026.06",
        }
        # New eb-local.lock under RLIMIT_FSIZE leaves neither eb-local.lock nor temp files.
        res_new_lock = self._run_dev(["--lock"], preexec_fn=_limit_fsize_lock, **resolved)
        self.assertGreater(res_new_lock.returncode, 0, f"rc={res_new_lock.returncode}: {res_new_lock.stderr!r}")
        self.assertIn("cannot write eb-local.lock", res_new_lock.stderr)
        self.assertEqual(sorted(p.name for p in self.work.iterdir()), [])

        # Existing .envrc and eb-local.lock stay intact with no leftover temp files.
        envrc = self.work / ".envrc"
        envrc.write_text("export KEEP_ME=1\n")
        envrc.chmod(0o640)
        lock = self.work / "eb-local.lock"
        lock.write_text('{"keep":true}\n')
        lock.chmod(0o600)

        res_upd_envrc = self._run_dev(["--envrc", "FFTW/3.3.10-GCC-15.2.0"], preexec_fn=_limit_fsize_32)
        self.assertGreater(res_upd_envrc.returncode, 0, f"rc={res_upd_envrc.returncode}: {res_upd_envrc.stderr!r}")
        self.assertEqual(envrc.read_text(), "export KEEP_ME=1\n")
        self.assertEqual(envrc.stat().st_mode & 0o777, 0o640)

        res_upd_lock = self._run_dev(["--lock"], preexec_fn=_limit_fsize_lock, **resolved)
        self.assertGreater(res_upd_lock.returncode, 0, f"rc={res_upd_lock.returncode}: {res_upd_lock.stderr!r}")
        self.assertEqual(lock.read_text(), '{"keep":true}\n')
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(p.name for p in self.work.iterdir()), [".envrc", "eb-local.lock"])


if __name__ == "__main__":
    unittest.main()
