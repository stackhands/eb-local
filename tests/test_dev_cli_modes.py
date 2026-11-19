#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local dev` module validation and warnings."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "dev is a feature of the Zig build")
class DevCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-dev-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.site = self.root / "site.toml"
        self.site.write_text('[storage]\nnode_local_root = "/local"\n', encoding="utf-8")
        self.site.chmod(0o600)

    def run_dev(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": str(self.site),
            "EB_LOCAL_PREFIX": str(self.prefix),
        }
        env.pop("LD_LIBRARY_PATH", None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, "dev", *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_invalid_module_names_exit_two(self):
        for bad in ("bad;module", "../escape/1.0", "Foo//1.0"):
            with self.subTest(bad=bad):
                got = self.run_dev([bad])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("is not a module name", got.stderr)

    def test_json_is_the_change_the_dev_lines_make(self):
        got = self.run_dev(["--json"])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout.count("\n"), 1, got.stdout)
        change = json.loads(got.stdout)
        self.assertEqual(change["kind"], "dev")
        values = {var["name"]: var["value"] for var in change["set"]}
        self.assertIn("EB_LOCAL_DEV_PREFIX", values)
        self.assertTrue(values["EB_LOCAL_DEV_PREFIX"].startswith(str(self.prefix) + "/dev/"), values)
        self.assertNotIn("module load", got.stdout)

    def test_names_the_host_ca_bundle_without_replacing_one_the_shell_set(self):
        got = self.run_dev([])
        self.assertEqual(got.returncode, 0, got.stderr)
        start = got.stdout.index("if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then")
        block = got.stdout[start:got.stdout.index("\nfi\n", start) + 4]
        self.assertLess(got.stdout.rindex("module load"), start)

        def after(present, **given):
            # The block with its three host paths under a scratch root.
            with tempfile.TemporaryDirectory() as root:
                for rel in present:
                    path = Path(root) / rel
                    path.parent.mkdir(parents=True)
                    path.write_text("")
                script = block.replace("/etc/", root + "/etc/")
                script += 'printf "%s|%s" "${SSL_CERT_FILE-}" "${CARGO_HTTP_CAINFO-}"\n'
                env = {"PATH": os.environ["PATH"], **given}
                run = subprocess.run(["bash", "-euc", script], env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)
                return run.stdout.replace(root, "")

        rhel = "etc/pki/tls/certs/ca-bundle.crt"
        self.assertEqual(after([rhel]), f"/{rhel}|/{rhel}")
        self.assertEqual(after([rhel], SSL_CERT_FILE="/mine.pem"), f"/mine.pem|/{rhel}")
        self.assertEqual(after([rhel], CARGO_HTTP_CAINFO="/mine.pem"), f"/{rhel}|/mine.pem")
        self.assertEqual(after([rhel, "etc/ssl/certs/ca-certificates.crt"]), "|")
        self.assertEqual(after(["etc/ssl/ca-bundle.pem"]), "/etc/ssl/ca-bundle.pem|/etc/ssl/ca-bundle.pem")
        self.assertEqual(after([]), "|")

    def test_deduplicates_modules_and_warns_for_gcc_buildenv_with_lfoss_module(self):
        got = self.run_dev(
            [
                "--buildenv",
                "buildenv/default-foss-2026.1",
                "ScaLAPACK/2.2.2-lfoss-2026.1",
                "ScaLAPACK/2.2.2-lfoss-2026.1",
                "buildenv/default-foss-2026.1",
            ],
            LD_LIBRARY_PATH="/host/lib",
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("belongs to the lfoss toolchain", got.stderr)
        self.assertIn("LD_LIBRARY_PATH is set", got.stderr)
        self.assertIn("module load ScaLAPACK/2.2.2-lfoss-2026.1\n", got.stdout)
        self.assertEqual(got.stdout.count("ScaLAPACK/2.2.2-lfoss-2026.1"), 1)
        self.assertIn("module load buildenv/default-foss-2026.1\n", got.stdout)
        self.assertIn("export EB_LOCAL_DEV_PREFIX=", got.stdout)

    def test_strict_prepends_cvmfs_init_check_before_module_loads(self):
        got = self.run_dev(["--strict", "--buildenv", "buildenv/custom", "Demo/1.0"])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("mount EESSI with CVMFS", got.stdout)
        self.assertLess(got.stdout.index("mount EESSI with CVMFS"), got.stdout.index("module load Demo/1.0"))

    def test_strict_dev_exits_two_when_eessi_init_path_is_a_directory(self):
        repo = self.root / "repo"
        init_dir = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_dir.mkdir(parents=True)
        got = self.run_dev(["--strict"], EESSI_CVMFS_REPO=str(repo))
        self.assertEqual(got.returncode, 0, got.stderr)
        proc = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", got.stdout],
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.root),
                "EESSI_CVMFS_REPO": str(repo),
                "LMOD_PKG": str(self.root / "no-lmod"),
            },
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("CVMFS", proc.stderr)


if __name__ == "__main__":
    unittest.main()
