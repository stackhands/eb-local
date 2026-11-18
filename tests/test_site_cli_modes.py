#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local site` subactions, template rendering, and refusals."""
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "site is a feature of the Zig build")
class SiteCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-site-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def run_site(self, args):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
        }
        return subprocess.run(
            [binary.BIN, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_option_conflicts_bad_actions_and_explain_exit_two(self):
        dest = self.root / "out.toml"
        cases = (
            (["site", "list", "extra"], "site list takes nothing else"),
            (["site", "list", "--force"], "site list takes nothing else"),
            (["site", "show", "--json", "slurm"], "--json goes with site list"),
            (["site", "show", "--to", str(dest), "slurm"], "site show prints the file"),
            (["site", "show", "--force", "slurm"], "site show prints the file"),
            (["site", "check"], "site check takes one configuration file"),
            (["site", "check", str(dest), "--force"], "site check takes only a configuration file"),
            (["site", "bogus"], "site takes list, show NAME or install NAME"),
            (["--explain", "site", "list"], "--explain goes with a recipe or with eb"),
        )
        for args, msg in cases:
            with self.subTest(args=args):
                got = self.run_site(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(msg, got.stderr)

    def test_list_json_and_install_force_directory_and_check_roundtrip(self):
        listed = self.run_site(["site", "list", "--json"])
        self.assertEqual(listed.returncode, 0, listed.stderr)
        doc = json.loads(listed.stdout)
        names = [t["name"] for t in doc["templates"]]
        self.assertIn("slurm", names)

        as_dir = self.run_site([
            "site", "install", "slurm",
            "--set", "node_local_root=/scratch",
            "--set", "shared_scratch=/shared",
            "--to", f"{self.root}/",
        ])
        self.assertEqual(as_dir.returncode, 2, as_dir.stdout + as_dir.stderr)
        self.assertIn("is a directory", as_dir.stderr)

        target = self.root / "config.toml"
        installed = self.run_site([
            "site", "install", "slurm",
            "--set=node_local_root=/scratch",
            "--set=shared_scratch=/shared",
            "--to", str(target),
        ])
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

        no_force = self.run_site([
            "site", "install", "slurm",
            "--set", "node_local_root=/scratch2",
            "--set", "shared_scratch=/shared",
            "--to", str(target),
        ])
        self.assertEqual(no_force.returncode, 2, no_force.stdout + no_force.stderr)
        self.assertIn("--force replaces it", no_force.stderr)

        forced = self.run_site([
            "site", "install", "slurm",
            "--set", "node_local_root=/scratch2",
            "--set", "shared_scratch=/shared",
            "--to", str(target),
            "--force",
        ])
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertIn("/scratch2", target.read_text(encoding="utf-8"))

        checked = self.run_site(["site", "check", str(target)])
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("is valid", checked.stdout)

    def test_check_accepts_valid_legacy_conf_and_rejects_malformed_legacy_conf(self):
        good = self.root / "good.conf"
        good.write_text("node_local_root = /scratch\n", encoding="utf-8")
        ok = self.run_site(["site", "check", str(good)])
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("is valid", ok.stdout)

        bad = self.root / "bad.conf"
        bad.write_text("bogus_key = yes\n", encoding="utf-8")
        err = self.run_site(["site", "check", str(bad)])
        self.assertEqual(err.returncode, 2, err.stdout + err.stderr)
        self.assertEqual(err.stdout, "")


if __name__ == "__main__":
    unittest.main()
