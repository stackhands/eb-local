#!/usr/bin/env python3
"""Logs directory behavior on read-only or full filesystems (EROFS, ENOSPC, RLIMIT_FSIZE)."""

import os
from pathlib import Path
import resource
import shutil
import subprocess
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(binary.ZIG, "logs directory filesystem checks target the Zig build")
class LogsDirFilesystemErrors(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def _site_with_secret(self, extra_storage=""):
        token = self.root / "token"
        token.write_text("tok-3141-secret\n")
        token.chmod(0o600)
        site = self.root / "site.toml"
        site.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\n{extra_storage}'
            f'[secrets]\nSOURCE_TOKEN = "file:{token}"\n'
        )
        site.chmod(0o600)
        return site

    def _named_job_mount(self, name):
        """Create `node-mounts/<name>` and point this job's mount table at it.

        `StorageFixture` creates `<user>.123`. A site that sets
        `node_local_mount` to a fixed name, such as `ubuntu.%j`, looks
        for that directory instead, and only finds it when the user is
        `ubuntu`.
        """
        mount = self.nodes / name
        mount.mkdir(exist_ok=True)
        return mount, {"CONTROL_JOB_ROOT": str(mount), "TMPDIR": str(mount)}

    def test_clean_build_with_secrets_keeps_default_raw_bytes(self):
        site = self._site_with_secret()
        eb_echo = r'''
eb() {
    python3 - "$@" <<'PY'
import os
v = os.environ["SOURCE_TOKEN"]
logs = os.environ["EASYBUILD_TMP_LOGDIR"]
open(os.path.join(logs, "easybuild-x.log"), "w").write(f"raw {v}\n")
PY
}
export -f eb
'''
        doubles = self.root / "doubles-clean.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_echo)
        argv, env = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, BASH_ENV=str(doubles)),
        )
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stderr, b"")
        self.assertIn(b"eb-local: removed secret values from 1 log file(s)\n", run.stdout)
        self.assertIn(b"eb-local: done. To use the modules in a new shell or job:\n", run.stdout)

    def test_readonly_logs_dir_stops_before_build_and_names_path_and_errno(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True)
        logs.chmod(0o555)
        try:
            run = self.run_wrapper()
        finally:
            logs.chmod(0o755)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertNotIn("eb-local: installing into", run.stdout)
        self.assertNotIn("eb-local: done.", run.stdout)
        self.assertIn(str(logs), run.stderr)
        self.assertIn("[Errno 13] Permission denied", run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])

    def test_erofs_logs_precheck_stops_before_build(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        job, mount_env = self._named_job_mount("ubuntu.123")
        token = self.root / "token"
        token.write_text("tok-3141-secret\n")
        token.chmod(0o600)
        site_nosec = self.root / "site-nosec.toml"
        site_nosec.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "ubuntu.%j"\n'
        )
        site_nosec.chmod(0o600)
        site_sec = self.root / "site-sec.toml"
        site_sec.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "ubuntu.%j"\n'
            f'[secrets]\nSOURCE_TOKEN = "file:{token}"\n'
        )
        site_sec.chmod(0o600)
        for cfg in (site_nosec, site_sec):
            with self.subTest(cfg=cfg.name):
                run = self.run_wrapper(
                    ["--config", str(cfg), "recipe.eb"],
                    EB_LOCAL_TEST_LOGS_ERRNO="EROFS",
                    **mount_env,
                )
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertNotIn("eb-local: installing into", run.stdout)
                self.assertNotIn("eb-local: done.", run.stdout)
                self.assertIn(str(logs), run.stderr)
                self.assertIn("[Errno 30] Read-only file system", run.stderr)
                self.assertEqual(list(job.iterdir()), [])

    def test_unreadable_dir_during_redaction_names_path_and_errno(self):
        rows = [
            (
                "logs",
                "easybuild-x.log",
                "logs = os.environ[\"EASYBUILD_TMP_LOGDIR\"]\n"
                "open(os.path.join(logs, \"easybuild-x.log\"), \"w\").write(f\"raw {v}\\n\")\n"
                "os.chmod(logs, 0o000)\n",
            ),
            (
                "versions",
                "easybuild-v.log",
                "versions = os.path.join(os.environ[\"EESSI_USER_INSTALL\"], \"versions\")\n"
                "os.makedirs(versions, exist_ok=True)\n"
                "open(os.path.join(versions, \"easybuild-v.log\"), \"w\").write(f\"raw {v}\\n\")\n"
                "os.chmod(versions, 0o000)\n",
            ),
        ]
        for kind, log_name, setup in rows:
            with self.subTest(directory=kind, log_name=log_name):
                site = self._site_with_secret()
                eb_lock = (
                    "eb() {\n"
                    "    python3 - \"$@\" <<'PY'\n"
                    "import os\n"
                    "v = os.environ[\"SOURCE_TOKEN\"]\n"
                    f"{setup}"
                    "PY\n"
                    "}\n"
                    "export -f eb\n"
                )
                doubles = self.root / f"doubles-lock-{kind}.sh"
                doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_lock)
                argv, env = binary.command(
                    self.script,
                    ["--config", str(site), "recipe.eb"],
                    dict(self.env, BASH_ENV=str(doubles)),
                )
                expected = (
                    self.prefix / ".eb-local" / "logs"
                    if kind == "logs"
                    else self.prefix / "versions"
                )
                try:
                    run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
                finally:
                    if expected.exists():
                        expected.chmod(0o700)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn(str(expected), run.stderr)
                self.assertIn("[Errno 13] Permission denied", run.stderr)
                self.assertIn("inspect it before sharing", run.stderr)

    def test_rlimit_fsize_on_logs_reports_path_and_errno_truthfully(self):
        site = self._site_with_secret()
        # The unredacted log (4087 bytes) fits under RLIMIT_FSIZE=4096, while
        # replacing the 15-byte secret with the 38-byte marker produces 4110
        # bytes and hits EFBIG.
        eb_small = r'''
eb() {
    python3 - "$@" <<'PY'
import os
v = os.environ["SOURCE_TOKEN"]
logs = os.environ["EASYBUILD_TMP_LOGDIR"]
open(os.path.join(logs, "easybuild-x.log"), "w").write("x" * 4071 + f" {v}\n")
open(os.path.join(logs, "small.log"), "w").write(f"s {v}\n")
PY
}
export -f eb
'''
        doubles = self.root / "doubles-fsize.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_small)
        argv, env = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, BASH_ENV=str(doubles)),
        )
        _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)

        def limit_fsize():
            resource.setrlimit(resource.RLIMIT_FSIZE, (4096, hard))

        run = subprocess.run(
            argv,
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
            preexec_fn=limit_fsize,
        )
        log_file = self.prefix / ".eb-local" / "logs" / "easybuild-x.log"
        small_file = self.prefix / ".eb-local" / "logs" / "small.log"
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(log_file), run.stderr)
        self.assertIn("[Errno 27] File too large", run.stderr)
        self.assertIn("remove them before sharing", run.stderr)
        self.assertEqual(log_file.read_text(), "x" * 4071 + " tok-3141-secret\n")
        self.assertEqual(small_file.read_text(), "s <secret SOURCE_TOKEN removed by eb-local>\n")
        self.assertIn("eb-local: done.", run.stdout)
        self.assertEqual(list(self.job.iterdir()), [])

    def test_enospc_on_log_redaction_names_path_and_errno(self):
        _, mount_env = self._named_job_mount("ubuntu.123")
        site = self._site_with_secret('node_local_mount = "ubuntu.%j"\n')
        eb_sec = r"""
eb() {
    python3 - "$@" <<'PY'
import os
v = os.environ["SOURCE_TOKEN"]
logs = os.environ["EASYBUILD_TMP_LOGDIR"]
with open(os.path.join(logs, "easybuild-sec.log"), "w") as f:
    f.write(f"leak {v}\n")
PY
}
export -f eb
"""
        doubles = self.root / "doubles-enospc-redact.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_sec)
        run = self.run_wrapper(
            ["--config", str(site), "recipe.eb"],
            BASH_ENV=str(doubles),
            EB_LOCAL_TEST_REDACT_ERRNO="ENOSPC",
            **mount_env,
        )
        logs = self.prefix / ".eb-local" / "logs"
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(logs / "easybuild-sec.log"), run.stderr)
        self.assertIn("[Errno 28] No space left on device", run.stderr)
        self.assertIn("remove them before sharing", run.stderr)
        self.assertIn("eb-local: done.", run.stdout)

    def test_workspace_create_enospc_removes_workspace_and_reports_errno(self):
        run = self.run_wrapper(EB_LOCAL_TEST_WORKSPACE_ERRNO="ENOSPC")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("[Errno 28] No space left on device", run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])

if __name__ == "__main__":
    unittest.main()
