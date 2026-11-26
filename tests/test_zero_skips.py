"""Regression tests for zero-skip Python discovery locally and in CI."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import binary
import hostile_fs

ROOT = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent


@unittest.skipUnless(binary.BIN, "requires compiled eb-local binary")
class ZeroPythonSkips(unittest.TestCase):
    def test_overlay_real_eb_stack_runs_from_path_with_zero_skips(self):
        eb_stack = shutil.which("eb-stack")
        self.assertIsNotNone(eb_stack, "eb-stack must be installed on PATH")
        with tempfile.TemporaryDirectory(prefix="eb-local-zero-skips-") as tmp:
            env = {
                "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
                "HOME": tmp,
                "PYTHONPATH": str(TESTS_DIR),
                "EB_LOCAL_BIN": binary.BIN,
            }
            run = subprocess.run(
                [sys.executable, "-m", "unittest", "-v", "test_overlay_real_eb_stack"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=30,
            )
        combined = run.stdout + run.stderr
        self.assertEqual(run.returncode, 0, combined)
        self.assertIn("Ran 2 tests", combined)
        self.assertNotIn("skipped", combined)

    def test_stale_eb_stack_on_path_skips_with_version_reason(self):
        with tempfile.TemporaryDirectory(prefix="eb-local-stale-eb-stack-") as tmp:
            tmp_path = Path(tmp)
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            marker = tmp_path / "invoked-package"
            fake_eb_stack = fake_bin / "eb-stack"
            fake_eb_stack.write_text(
                "#!/bin/sh\n"
                'if [ "$1" = "--version" ]; then\n'
                '  printf "eb-stack 0.7.9\\n"\n'
                "  exit 0\n"
                "fi\n"
                f'printf "unexpected" > "{marker}"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            fake_eb_stack.chmod(0o755)
            env = {
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "HOME": tmp,
                "PYTHONPATH": str(TESTS_DIR),
                "EB_LOCAL_BIN": binary.BIN,
            }
            run = subprocess.run(
                [sys.executable, "-m", "unittest", "-v", "test_overlay_real_eb_stack"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertFalse(marker.exists(), "stale eb-stack must not be executed past version check")
        combined = run.stdout + run.stderr
        self.assertEqual(run.returncode, 0, combined)
        self.assertIn("skipped", combined)
        self.assertIn("0.7.9", combined)
        self.assertIn("0.8.0 or newer", combined)

    def test_enter_without_host_paths_probes_and_skips_when_userns_blocked(self):
        self.assertTrue(
            hasattr(hostile_fs, "enter_without_host_paths"),
            "hostile_fs.enter_without_host_paths is missing",
        )
        with tempfile.TemporaryDirectory(prefix="eb-local-blocked-userns-") as tmp:
            tmp_path = Path(tmp)
            present_file = tmp_path / "site.toml"
            present_file.write_text("", encoding="utf-8")
            calls_log = tmp_path / "calls.log"
            fake_unshare = tmp_path / "unshare"
            fake_unshare.write_text(
                "#!/bin/sh\n"
                f'printf "%s\\n" "$*" >> "{calls_log}"\n'
                'echo "unshare: unshare failed: Operation not permitted" >&2\n'
                "exit 1\n",
                encoding="utf-8",
            )
            fake_unshare.chmod(0o755)
            real_which = shutil.which

            def patched_which(cmd, *args, **kwargs):
                if cmd == "unshare":
                    return str(fake_unshare)
                return real_which(cmd, *args, **kwargs)

            with mock.patch("hostile_fs.shutil.which", side_effect=patched_which):
                with self.assertRaises(unittest.SkipTest) as ctx:
                    hostile_fs.enter_without_host_paths(self, (str(present_file),))
            self.assertIn("user-namespace bind mounts unavailable", str(ctx.exception))
            logged = calls_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(logged), 1, f"expected only probe call, got: {logged}")

    def test_caller_shell_init_runs_with_zsh_and_zero_skips(self):
        zsh = shutil.which("zsh")
        self.assertIsNotNone(zsh, "zsh must be installed on PATH")
        with tempfile.TemporaryDirectory(prefix="eb-local-shell-init-") as tmp:
            env = {
                "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
                "HOME": tmp,
                "PYTHONPATH": str(TESTS_DIR),
                "EB_LOCAL_BIN": binary.BIN,
            }
            run = subprocess.run(
                [sys.executable, "-m", "unittest", "-v", "test_shell_init_cli.CallerShellInit"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=30,
            )
        combined = run.stdout + run.stderr
        self.assertEqual(run.returncode, 0, combined)
        self.assertIn("Ran 2 tests", combined)
        self.assertNotIn("skipped", combined)

    def test_host_lmod_and_site_files_are_isolated_instead_of_skipping(self):
        unshare = shutil.which("unshare")
        self.assertIsNotNone(unshare, "unshare must be available")
        uid = str(os.getuid())
        gid = str(os.getgid())

        targets = [
            "test_shell_init_cli.CallerShellInit.test_clean_callers_source_their_eessi_initializer",
            "test_lmod_init_cli.EessiLmod.test_a_build_sources_eessis_lmod_when_the_host_has_none",
            "test_lmod_init_cli.EessiLmod.test_doctor_without_a_site_file_warns_that_env_and_dev_need_a_module_command",
            "test_list_doctor_cli.ListAndDoctor.test_doctor_fails_where_no_directory_on_modulepath_holds_the_eessi_module",
            "test_list_doctor_cli.ListAndDoctor.test_doctor_fails_on_a_secret_every_build_would_stop_on",
            "test_list_doctor_cli.ListAndDoctor.test_doctor_without_a_site_file_judges_eb_local_eb",
        ]
        script = (
            'd=$(mktemp -d) && trap \'umount /etc >/dev/null 2>&1 || true; rm -rf "$d"\' EXIT && '
            'cp -a /etc/. "$d/" 2>/dev/null || true; '
            'mkdir -p "$d/profile.d" "$d/eb-local" && '
            'printf "%s\\n" "module() { return 0; }" > "$d/profile.d/lmod.sh" && '
            'printf "[storage]\\nnode_local_root = \\"/local\\"\\n" > "$d/eb-local/config.toml" && '
            'printf "EB_LOCAL_NODE_LOCAL_ROOT=/local\\n" > "$d/eb-local.conf" && '
            'chmod 0644 "$d/eb-local/config.toml" "$d/eb-local.conf" && '
            'mount --bind "$d" /etc && '
            'exec "$@"'
        )
        with tempfile.TemporaryDirectory(prefix="eb-local-host-mask-") as home:
            env = dict(
                os.environ,
                HOME=home,
                PYTHONPATH=str(TESTS_DIR),
                EB_LOCAL_BIN=binary.BIN,
            )
            run = subprocess.run(
                [
                    unshare,
                    "-U",
                    "--keep-caps",
                    f"--map-user={uid}",
                    f"--map-group={gid}",
                    "-m",
                    "/bin/sh",
                    "-c",
                    script,
                    "sh",
                    sys.executable,
                    "-m",
                    "unittest",
                    "-v",
                    *targets,
                ],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=120,
            )
        combined = run.stdout + run.stderr
        self.assertEqual(run.returncode, 0, combined)
        self.assertIn(f"Ran {len(targets)} tests", combined)
        self.assertNotIn("skipped", combined)


class LiveEessiOutsideZeroSkipDiscovery(unittest.TestCase):
    """`tests/site` stays out of discovery, and the live file fails closed."""

    def test_discovery_does_not_collect_the_site_module(self):
        site = TESTS_DIR / "site"
        self.assertFalse(
            (site / "__init__.py").exists(), "tests/site must not be a package"
        )
        names = sorted(path.name for path in site.rglob("test_*.py"))
        self.assertIn("test_dev_locked_eessi.py", names)
        for name in names:
            loader = unittest.TestLoader()
            suite = loader.discover(str(TESTS_DIR), pattern=name)
            self.assertEqual(loader.errors, [])
            self.assertEqual(suite.countTestCases(), 0, name)

    def test_the_live_class_has_no_skip_mark(self):
        import importlib.util

        path = TESTS_DIR / "site" / "test_dev_locked_eessi.py"
        spec = importlib.util.spec_from_file_location(
            "dev_locked_live_eessi_policy", path
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cls = module.DevLockedLiveEessiTests
        self.assertFalse(getattr(cls, "__unittest_skip__", False))
        self.assertTrue(
            hasattr(cls, "test_locked_avoids_duplicate_eessi_and_extend_reloads")
        )
        self.assertTrue(
            hasattr(
                cls, "test_locked_llvm_compilers_build_gets_rpath_without_not_found"
            )
        )

    def test_running_the_module_without_the_mount_fails(self):
        missing = TESTS_DIR / "site" / "no-such-eessi-init"
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": os.environ.get("HOME", "/tmp"),
            "EB_LOCAL_LIVE_EESSI_INIT": str(missing),
        }
        if binary.BIN:
            env["EB_LOCAL_BIN"] = binary.BIN
        run = subprocess.run(
            [
                sys.executable,
                "-m",
                "unittest",
                "-v",
                "tests/site/test_dev_locked_eessi.py",
            ],
            check=False,
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )
        combined = run.stdout + run.stderr
        self.assertNotEqual(run.returncode, 0, combined)
        self.assertNotIn("skipped", combined)
        self.assertIn("live EESSI 2026.06 on CVMFS", combined)
        self.assertIn(str(missing), combined)


if __name__ == "__main__":
    unittest.main()
