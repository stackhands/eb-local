#!/usr/bin/env python3
"""CLI subcommands report standard output write failures and exit 1."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


def run_dev_full(argv, *, env, cwd):
    with open("/dev/full", "wb") as dev_full:
        return subprocess.run(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=dev_full,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )


def run_closed_stdout(argv, *, env, cwd):
    return subprocess.run(
        ["/bin/sh", "-c", 'exec "$@" 1>&-', "sh", *argv],
        env=env,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )


@unittest.skipUnless(
    binary.BIN and os.path.exists("/dev/full"),
    "stdout write failure behavior belongs to the Zig binary on Linux",
)
class StdoutWriteErrorsCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-stdout-err-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.bins = self.root / "bin"
        self.bins.mkdir()
        self.local_root = self.root / "local"
        (self.local_root / "42").mkdir(parents=True)
        self.mountinfo = self.root / "mountinfo"
        self.mountinfo.write_text(
            "1 0 0:1 / / rw - ext4 /dev/root rw\n"
            f"2 1 0:2 / {self.local_root / '42'} rw,relatime - xfs /dev/node rw\n",
            encoding="utf-8",
        )
        self.site = self.root / "site.toml"
        self.site.write_text(
            f'[storage]\nnode_local_root = "{self.local_root}"\n'
            'node_local_mount = "%j"\n\n'
            '[build.node_types]\ncpu = "-p cpu -n 16"\n',
            encoding="utf-8",
        )
        self.site.chmod(0o600)

        # Compiler stub for rpath-wrappers, sbatch/eb sentinels for submit/build,
        # and rtrash stub for restore.
        gcc = self.bins / "gcc"
        gcc.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        gcc.chmod(0o755)

        self.sbatch_marker = self.root / "sbatch.ran"
        sbatch = self.bins / "sbatch"
        sbatch.write_text(
            f"#!/bin/sh\nprintf 'ran\\n' > '{self.sbatch_marker}'\nprintf '12345\\n'\n",
            encoding="utf-8",
        )
        sbatch.chmod(0o755)

        self.eb_marker = self.root / "eb.ran"
        eb = self.bins / "eb"
        eb.write_text(
            f"#!/bin/sh\nprintf 'ran\\n' > '{self.eb_marker}'\nexit 0\n",
            encoding="utf-8",
        )
        eb.chmod(0o755)

    def base_env(self, **extra):
        env = {
            "PATH": f"{self.bins}:/usr/bin:/bin",
            "HOME": str(self.root),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "EB_LOCAL_CONFIG": str(self.site),
            "EB_LOCAL_PREFIX": str(self.prefix),
            "SLURM_JOB_ID": "",
        }
        env.update(extra)
        return env

    def assert_both_sinks_fail(self, label, argv, *, env=None, cwd=None):
        run_env = self.base_env() if env is None else env
        run_cwd = self.root if cwd is None else cwd
        for sink_name, runner, expected_err in (
            ("dev-full", run_dev_full, "No space left on device"),
            ("closed-stdout", run_closed_stdout, "Bad file descriptor"),
        ):
            with self.subTest(command=label, sink=sink_name):
                got = runner(argv, env=run_env, cwd=run_cwd)
                self.assertEqual(got.returncode, 1, f"{label} ({sink_name}): {got.stderr}")
                self.assertIn("cannot write output", got.stderr)
                self.assertIn(expected_err, got.stderr)

    def test_help_version_and_explain_commands(self):
        recipe = self.root / "Demo-1.0.eb"
        recipe.write_text("name = 'Demo'\n", encoding="utf-8")
        for label, args in (
            ("help", ["help"]),
            ("-h", ["-h"]),
            ("--help", ["--help"]),
            ("dev --help", ["dev", "--help"]),
            ("--version", ["--version"]),
            ("--explain", ["--explain", str(recipe)]),
            ("--explain eb", ["--explain", "eb", "--version"]),
        ):
            self.assert_both_sinks_fail(label, [binary.BIN, *args])

    def test_shell_evaluation_commands(self):
        saved_proc = subprocess.run(
            [
                "/bin/sh",
                "-c",
                'module() { :; }; eval "$("$1" dev --replace Demo/1.0 2>/dev/null)"; printf "%s" "$EB_LOCAL_DEV_SAVED"',
                "sh",
                binary.BIN,
            ],
            env=self.base_env(),
            cwd=self.root,
            capture_output=True,
            text=True,
            check=True,
        )
        saved_raw = saved_proc.stdout
        self.assertTrue(saved_raw)

        lock_env = self.base_env(
            EESSI_VERSION="2023.06",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
            LOADEDMODULES="Demo/1.0",
            _LMFILES_="/cvmfs/software.eessi.io/versions/2023.06/software/linux/x86_64/amd/zen4/modules/all/Demo/1.0.lua",
        )
        subprocess.run(
            [binary.BIN, "dev", "--lock", "Demo/1.0"],
            env=lock_env,
            cwd=self.root,
            capture_output=True,
            text=True,
            check=True,
        )

        self.assert_both_sinks_fail("env", [binary.BIN, "env"])
        self.assert_both_sinks_fail("dev", [binary.BIN, "dev"])
        self.assert_both_sinks_fail("dev --locked", [binary.BIN, "dev", "--locked"], env=lock_env)
        self.assert_both_sinks_fail(
            "leave",
            [binary.BIN, "leave"],
            env=self.base_env(EB_LOCAL_DEV_SAVED=saved_raw),
        )
        self.assert_both_sinks_fail("rpath-wrappers", [binary.BIN, "rpath-wrappers"])

    def test_config_profiles_site_and_check_commands(self):
        empty_dir = self.root / "empty-check"
        empty_dir.mkdir()
        site_out = self.root / "installed-site.toml"

        self.assert_both_sinks_fail(
            "check",
            [binary.BIN, "check", "--dev"],
            env=self.base_env(EB_LOCAL_DEV_PREFIX=str(empty_dir)),
        )
        self.assert_both_sinks_fail("config", [binary.BIN, "config"])
        self.assert_both_sinks_fail("config --check", [binary.BIN, "config", "--check"])
        self.assert_both_sinks_fail("config --env", [binary.BIN, "config", "--env"])
        self.assert_both_sinks_fail("config --get", [binary.BIN, "config", "--get", "prefix"])
        self.assert_both_sinks_fail("profiles", [binary.BIN, "profiles"])
        self.assert_both_sinks_fail("site list", [binary.BIN, "site", "list"])
        self.assert_both_sinks_fail(
            "site show",
            [
                binary.BIN,
                "site",
                "show",
                "slurm",
                "--set",
                "node_local_root=/local",
                "--set",
                "shared_scratch=/scratch",
            ],
        )
        self.assert_both_sinks_fail("site check", [binary.BIN, "site", "check", str(self.site)])
        self.assert_both_sinks_fail(
            "site install",
            [
                binary.BIN,
                "site",
                "install",
                "slurm",
                "--set",
                "node_local_root=/local",
                "--set",
                "shared_scratch=/scratch",
                "--to",
                str(site_out),
                "--force",
            ],
        )

    def test_list_doctor_clean_uninstall_and_restore_commands(self):
        # Empty prefix list first.
        self.assert_both_sinks_fail("list (empty)", [binary.BIN, "list"])

        # Populate zen4 with Demo/1.0 so list, list --missing (from skylake),
        # uninstall, and restore all produce stdout.
        zen4 = self.prefix / "versions" / "2023.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        skylake = self.prefix / "versions" / "2023.06" / "software" / "linux" / "x86_64" / "intel" / "skylake_avx512"
        (zen4 / "software" / "Demo" / "1.0").mkdir(parents=True)
        (zen4 / "modules" / "all" / "Demo").mkdir(parents=True)
        (zen4 / "modules" / "all" / "Demo" / "1.0.lua").write_text("-- lua\n", encoding="utf-8")
        (skylake / "software").mkdir(parents=True)
        (skylake / "modules" / "all").mkdir(parents=True)

        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "easybuild-old.log").write_text("log\n", encoding="utf-8")

        trash_inst = skylake / "software" / "Restored" / "1.0"
        trash_mod = skylake / "modules" / "all" / "Restored" / "1.0.lua"
        payload = json.dumps(
            [
                {"original": str(trash_inst), "trash_dir": "/tmp/trash"},
                {"original": str(trash_mod), "trash_dir": "/tmp/trash"},
            ]
        )
        rtrash = self.bins / "rtrash"
        rtrash.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "list" ]; then\n'
            f"  printf '%s\\n' '{payload}'\n"
            "  exit 0\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        rtrash.chmod(0o755)

        ws = self.root / "ws"
        ws.mkdir()

        self.assert_both_sinks_fail("list (populated)", [binary.BIN, "list"])
        self.assert_both_sinks_fail(
            "list --missing",
            [binary.BIN, "list", "--missing"],
            env=self.base_env(
                EESSI_CVMFS_REPO="/cvmfs/software.eessi.io",
                EESSI_VERSION="2023.06",
                EESSI_SOFTWARE_SUBDIR="x86_64/intel/skylake_avx512",
            ),
        )
        self.assert_both_sinks_fail("doctor", [binary.BIN, "doctor", "--workspace", str(ws)])
        self.assert_both_sinks_fail("clean --dry-run", [binary.BIN, "clean", "--dry-run"])
        self.assert_both_sinks_fail(
            "uninstall --dry-run",
            [binary.BIN, "uninstall", "--dry-run", "Demo/1.0"],
        )
        self.assert_both_sinks_fail(
            "restore --dry-run",
            [binary.BIN, "restore", "--dry-run", "Restored/1.0"],
        )

    def test_submit_and_build_abort_before_side_effects_when_stdout_fails(self):
        recipe = self.root / "Demo-1.0.eb"
        recipe.write_text("name = 'Demo'\n", encoding="utf-8")

        self.assert_both_sinks_fail("submit --print", [binary.BIN, "submit", "--print", str(recipe)])

        for sink_name, runner, expected_err in (
            ("dev-full", run_dev_full, "No space left on device"),
            ("closed-stdout", run_closed_stdout, "Bad file descriptor"),
        ):
            with self.subTest(command="submit", sink=sink_name):
                got = runner([binary.BIN, "submit", str(recipe)], env=self.base_env(), cwd=self.root)
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("cannot write output", got.stderr)
                self.assertIn(expected_err, got.stderr)
                self.assertFalse(self.sbatch_marker.exists(), "sbatch must not run after stdout fails")
                jobs_dir = self.prefix / ".eb-local" / "jobs"
                if jobs_dir.exists():
                    self.assertEqual(list(jobs_dir.iterdir()), [])

            with self.subTest(command="build", sink=sink_name):
                got = runner(
                    [binary.BIN, str(recipe)],
                    env=self.base_env(
                        SLURM_JOB_ID="42",
                        EB_LOCAL_TEST_MOUNTINFO=str(self.mountinfo),
                    ),
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("cannot write output", got.stderr)
                self.assertIn(expected_err, got.stderr)
                self.assertFalse(self.eb_marker.exists(), "eb must not run after stdout fails")
                self.assertEqual(list((self.local_root / "42").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
