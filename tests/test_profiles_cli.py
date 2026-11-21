#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local profiles`."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.ZIG, "profiles is a feature of the Zig build")
class ProfilesCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-profiles-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / "home"
        self.xdg = self.root / "xdg"
        self.home.mkdir()
        self.xdg.mkdir()
        self.site = self.root / "site.toml"
        self.user = self.xdg / "eb-local" / "config.toml"

    def run_profiles(self, *args, site_path=None):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.xdg),
            "EB_LOCAL_CONFIG": "" if site_path is None else str(site_path),
        }
        return subprocess.run(
            [binary.ZIG, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_empty_profiles_text_and_json_output(self):
        text = self.run_profiles("profiles")
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertEqual(text.stderr, "")
        self.assertEqual(text.stdout, "no profiles are defined\n")

        doc_run = self.run_profiles("profiles", "--json")
        self.assertEqual(doc_run.returncode, 0, doc_run.stderr)
        self.assertEqual(doc_run.stderr, "")
        doc = json.loads(doc_run.stdout)
        self.assertEqual(doc, {"schema_version": 1, "kind": "profiles", "profiles": []})

    def test_multi_layer_profiles_list_both_site_and_user_layers(self):
        self.site.write_text(
            '[storage]\nnode_local_root = "/local"\n[profile.gpu]\ndev.modules = ["CUDA/13.3.0"]\n',
            encoding="utf-8",
        )
        self.site.chmod(0o600)
        self.user.parent.mkdir(parents=True)
        self.user.write_text('[profile.mine]\nprefix = "~/my-eessi"\n', encoding="utf-8")
        self.user.chmod(0o600)

        doc_run = self.run_profiles("profiles", "--json", site_path=self.site)
        self.assertEqual(doc_run.returncode, 0, doc_run.stderr)
        self.assertEqual(doc_run.stderr, "")
        doc = json.loads(doc_run.stdout)
        self.assertEqual(doc["schema_version"], 1)
        self.assertEqual(doc["kind"], "profiles")
        self.assertEqual(
            doc["profiles"],
            [
                {"name": "gpu", "layer": "site", "path": str(self.site)},
                {"name": "mine", "layer": "user", "path": str(self.user)},
            ],
        )

        text = self.run_profiles("profiles", site_path=self.site)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn(f"gpu                  site {self.site}\n", text.stdout)
        self.assertIn(f"mine                 user {self.user}\n", text.stdout)

    def test_non_empty_profiles_text_does_not_claim_none_defined(self):
        self.site.write_text('[storage]\nnode_local_root = "/local"\n[profile.gpu]\ndev.modules = ["CUDA/13.3.0"]\n', encoding="utf-8")
        self.site.chmod(0o600)
        text = self.run_profiles("profiles", site_path=self.site)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertNotIn("no profiles are defined", text.stdout)

    def test_broken_profile_in_config_exits_two_in_both_text_and_json_modes(self):
        self.user.parent.mkdir(parents=True)
        self.user.write_text('[profile.bad.storage]\nnode_local_root = "/local"\n', encoding="utf-8")
        self.user.chmod(0o600)

        for extra in ([], ["--json"]):
            with self.subTest(extra=extra):
                got = self.run_profiles("profiles", *extra)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("storage", got.stderr)


if __name__ == "__main__":
    unittest.main()
