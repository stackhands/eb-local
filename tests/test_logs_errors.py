#!/usr/bin/env python3
"""Logs directory behavior on read-only or full filesystems (EROFS, ENOSPC, RLIMIT_FSIZE)."""

import os
from pathlib import Path
import pwd
import resource
import shutil
import subprocess
import unittest

import binary
from test_storage import StorageFixture


def _can_mount_tmpfs():
    probe = subprocess.run(
        [
            "unshare",
            "-r",
            "-m",
            "sh",
            "-c",
            "d=$(mktemp -d) && mount -t tmpfs -o size=64k tmpfs \"$d\" && umount \"$d\" && rmdir \"$d\"",
        ],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


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

    def test_clean_build_output_bytes_stay_unchanged(self):
        argv, env = binary.command(self.script, ["recipe.eb"], dict(self.env))
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stderr, b"")
        self.assertIn(b"eb-local: done. To use the modules in a new shell or job:\n", run.stdout)

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

    @unittest.skipUnless(_can_mount_tmpfs(), "user-namespace tmpfs mounts unavailable in this environment")
    def test_tmpfs_erofs_precheck_stops_before_build(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        token = self.root / "token"
        token.write_text("tok-3141-secret\n")
        token.chmod(0o600)
        user = pwd.getpwuid(os.getuid()).pw_name
        site_nosec = self.root / "site-nosec.toml"
        site_nosec.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\n'
            f'node_local_mount = "{user}.%j"\n'
        )
        site_nosec.chmod(0o600)
        site_sec = self.root / "site-sec.toml"
        site_sec.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\n'
            f'node_local_mount = "{user}.%j"\n'
            f'[secrets]\nSOURCE_TOKEN = "file:{token}"\n'
        )
        site_sec.chmod(0o600)

        for cfg in (site_nosec, site_sec):
            argv, env = binary.command(self.script, ["--config", str(cfg), "recipe.eb"], dict(self.env))
            ro_cmd = [
                "unshare",
                "-r",
                "-m",
                "python3",
                "-c",
                (
                    "import subprocess, sys\n"
                    "logs, argv = sys.argv[1], sys.argv[2:]\n"
                    "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=64k,ro', 'tmpfs', logs], check=True)\n"
                    "try:\n"
                    "    p = subprocess.run(argv)\n"
                    "    sys.exit(p.returncode)\n"
                    "finally:\n"
                    "    subprocess.run(['umount', logs], check=False)\n"
                ),
                str(logs),
                *argv,
            ]
            ro_run = subprocess.run(ro_cmd, env=env, cwd=self.root, capture_output=True, text=True)
            self.assertEqual(ro_run.returncode, 2, ro_run.stdout + ro_run.stderr)
            self.assertNotIn("eb-local: installing into", ro_run.stdout)
            self.assertNotIn("eb-local: done.", ro_run.stdout)
            self.assertIn(str(logs), ro_run.stderr)
            self.assertIn("[Errno 30] Read-only file system", ro_run.stderr)
            self.assertEqual(list(self.job.iterdir()), [])

    def test_unreadable_logs_dir_during_redaction_names_path_and_errno(self):
        site = self._site_with_secret()
        eb_lock = r'''
eb() {
    python3 - "$@" <<'PY'
import os
v = os.environ["SOURCE_TOKEN"]
logs = os.environ["EASYBUILD_TMP_LOGDIR"]
open(os.path.join(logs, "easybuild-x.log"), "w").write(f"raw {v}\n")
os.chmod(logs, 0o000)
PY
}
export -f eb
'''
        doubles = self.root / "doubles-lock.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_lock)
        argv, env = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, BASH_ENV=str(doubles)),
        )
        logs = self.prefix / ".eb-local" / "logs"
        try:
            run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        finally:
            if logs.exists():
                logs.chmod(0o700)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(logs), run.stderr)
        self.assertIn("[Errno 13] Permission denied", run.stderr)
        self.assertIn("inspect it before sharing", run.stderr)

    def test_unreadable_versions_dir_during_redaction_names_path_and_errno(self):
        site = self._site_with_secret()
        eb_lock = r'''
eb() {
    python3 - "$@" <<'PY'
import os
v = os.environ["SOURCE_TOKEN"]
versions = os.path.join(os.environ["EESSI_USER_INSTALL"], "versions")
os.makedirs(versions, exist_ok=True)
open(os.path.join(versions, "easybuild-v.log"), "w").write(f"raw {v}\n")
os.chmod(versions, 0o000)
PY
}
export -f eb
'''
        doubles = self.root / "doubles-lock-versions.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_lock)
        argv, env = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, BASH_ENV=str(doubles)),
        )
        versions = self.prefix / "versions"
        try:
            run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        finally:
            if versions.exists():
                versions.chmod(0o700)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(versions), run.stderr)
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

    @unittest.skipUnless(_can_mount_tmpfs(), "user-namespace tmpfs mounts unavailable in this environment")
    def test_tmpfs_enospc_on_logs_dir(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        user = pwd.getpwuid(os.getuid()).pw_name
        site = self._site_with_secret(f'node_local_mount = "{user}.%j"\n')

        # 1. Small tmpfs filled so eb hits ENOSPC writing its log: build fails truthfully.
        eb_fail = r'''
eb() {
    python3 - "$@" <<'PY'
import os, sys
logs = os.environ["EASYBUILD_TMP_LOGDIR"]
try:
    with open(os.path.join(logs, "easybuild-big.log"), "wb") as f:
        f.write(b"a" * 16384)
except OSError as e:
    print(f"eb: log write failed: {e}", file=sys.stderr)
    sys.exit(1)
PY
}
export -f eb
'''
        doubles_fail = self.root / "doubles-enospc-eb.sh"
        doubles_fail.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_fail)
        argv_fail, env_fail = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, BASH_ENV=str(doubles_fail)),
        )
        enospc_eb_cmd = [
            "unshare",
            "-r",
            "-m",
            "python3",
            "-c",
            (
                "import os, subprocess, sys\n"
                "logs, argv = sys.argv[1], sys.argv[2:]\n"
                "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=8k', 'tmpfs', logs], check=True)\n"
                "try:\n"
                "    with open(os.path.join(logs, 'fill'), 'wb') as f:\n"
                "        f.write(b'x' * 4096)\n"
                "    p = subprocess.run(argv)\n"
                "    sys.exit(p.returncode)\n"
                "finally:\n"
                "    subprocess.run(['umount', logs], check=False)\n"
            ),
            str(logs),
            *argv_fail,
        ]
        fail_run = subprocess.run(enospc_eb_cmd, env=env_fail, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(fail_run.returncode, 1, fail_run.stdout + fail_run.stderr)
        self.assertNotIn("eb-local: done.", fail_run.stdout)
        self.assertIn("No space left on device", fail_run.stderr)
        for w in list(self.job.iterdir()):
            shutil.rmtree(w)

        # 2. Small tmpfs (8k): 4k filler + 1 page secret log succeeds in eb, then
        # redaction hits ENOSPC writing the replacement temp file and names path+errno.
        eb_sec = r'''
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
'''
        doubles_sec = self.root / "doubles-enospc-redact.sh"
        doubles_sec.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_sec)
        argv_sec, env_sec = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, BASH_ENV=str(doubles_sec)),
        )
        enospc_red_cmd = [
            "unshare",
            "-r",
            "-m",
            "python3",
            "-c",
            (
                "import os, subprocess, sys\n"
                "logs, argv = sys.argv[1], sys.argv[2:]\n"
                "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=8k', 'tmpfs', logs], check=True)\n"
                "try:\n"
                "    with open(os.path.join(logs, 'fill'), 'wb') as f:\n"
                "        f.write(b'x' * 4096)\n"
                "    p = subprocess.run(argv)\n"
                "    sys.exit(p.returncode)\n"
                "finally:\n"
                "    subprocess.run(['umount', logs], check=False)\n"
            ),
            str(logs),
            *argv_sec,
        ]
        red_run = subprocess.run(enospc_red_cmd, env=env_sec, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(red_run.returncode, 0, red_run.stdout + red_run.stderr)
        self.assertIn(str(logs / "easybuild-sec.log"), red_run.stderr)
        self.assertIn("[Errno 28] No space left on device", red_run.stderr)
        self.assertIn("remove them before sharing", red_run.stderr)
        self.assertIn("eb-local: done.", red_run.stdout)

    @unittest.skipUnless(_can_mount_tmpfs(), "user-namespace tmpfs mounts unavailable in this environment")
    def test_workspace_subdir_enospc_removes_workspace_and_reports_errno(self):
        root_job = self.nodes / "root.123"
        root_job.mkdir()
        site = self.root / "site-ws.toml"
        site.write_text(f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "%u.%j"\n')
        site.chmod(0o600)
        argv, env = binary.command(
            self.script,
            ["--config", str(site), "recipe.eb"],
            dict(self.env, CONTROL_JOB_ROOT=str(root_job), TMPDIR=str(root_job)),
        )
        cmd = [
            "unshare",
            "-r",
            "-m",
            "python3",
            "-c",
            (
                "import os, subprocess, sys\n"
                "jr, argv = sys.argv[1], sys.argv[2:]\n"
                "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=64k,nr_inodes=2', 'tmpfs', jr], check=True)\n"
                "try:\n"
                "    p = subprocess.run(argv)\n"
                "    left = os.listdir(jr)\n"
                "    if left:\n"
                "        sys.stderr.write('LEAKED_WORK=' + repr(left) + '\\n')\n"
                "    sys.exit(p.returncode)\n"
                "finally:\n"
                "    subprocess.run(['umount', jr], check=False)\n"
            ),
            str(root_job),
            *argv,
        ]
        run = subprocess.run(cmd, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("[Errno 28] No space left on device", run.stderr)
        self.assertNotIn("LEAKED_WORK=", run.stderr)


if __name__ == "__main__":
    unittest.main()
