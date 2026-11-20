#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local list` filters, multi-version labels, and refusals."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "list is a feature of the Zig build")
class ListCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-list-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"

    def run_list(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "EB_LOCAL_PREFIX": str(self.prefix),
        }
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, "list", *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_missing_requires_loaded_target_and_rejects_json_or_bad_filter(self):
        no_target = self.run_list(["--missing"], EESSI_SOFTWARE_SUBDIR="")
        self.assertEqual(no_target.returncode, 2, no_target.stdout + no_target.stderr)
        self.assertIn("list --missing needs EESSI loaded", no_target.stderr)

        both = self.run_list(["--missing", "--json"])
        self.assertEqual(both.returncode, 2, both.stdout + both.stderr)
        self.assertIn("list takes --missing or --json, not both", both.stderr)

        for bad in ("bad;name", "../escape/1.0", "Foo//1.0"):
            with self.subTest(bad=bad):
                bad_filter = self.run_list([bad])
                self.assertEqual(bad_filter.returncode, 2, bad_filter.stdout + bad_filter.stderr)
                self.assertIn("is not a module name", bad_filter.stderr)

    def test_multi_version_trees_disambiguate_column_labels_and_missing_output(self):
        for ver, mod_ver in (("2025.06", "1.0"), ("2026.06", "2.0")):
            tree = self.prefix / "versions" / ver / "software" / "linux" / "x86_64" / "amd" / "zen4"
            (tree / "software" / "Demo" / mod_ver).mkdir(parents=True)
            mod = tree / "modules" / "all" / "Demo" / f"{mod_ver}.lua"
            mod.parent.mkdir(parents=True)
            mod.write_text("-- demo\n", encoding="utf-8")

        text = self.run_list(
            [],
            EESSI_VERSION="2026.06",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
        )
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("2025.06:x86_64/amd/zen4  2026.06:x86_64/amd/zen4*", text.stdout)
        self.assertIn("Demo/1.0  x", text.stdout)
        self.assertIn("Demo/2.0  -", text.stdout)

        only_missing = self.run_list(
            ["--missing"],
            EESSI_VERSION="2026.06",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
        )
        self.assertEqual(only_missing.returncode, 0, only_missing.stderr)
        self.assertEqual(only_missing.stdout, "Demo/1.0\n")

        doc_run = self.run_list(
            ["--json"],
            EESSI_VERSION="2026.06",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
        )
        self.assertEqual(doc_run.returncode, 0, doc_run.stderr)
        doc = json.loads(doc_run.stdout)
        self.assertEqual(
            doc["targets"],
            [
                {"label": "2025.06:x86_64/amd/zen4", "here": False},
                {"label": "2026.06:x86_64/amd/zen4", "here": True},
            ],
        )
        self.assertEqual(doc["missing_on_node"], ["Demo/1.0"])

    def test_symlinked_versions_dir_is_ignored_without_error(self):
        real_ver = self.root / "real-versions"
        tree = real_ver / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (tree / "software" / "Demo" / "1.0").mkdir(parents=True)
        mod = tree / "modules" / "all" / "Demo" / "1.0.lua"
        mod.parent.mkdir(parents=True)
        mod.write_text("-- demo\n", encoding="utf-8")
        self.prefix.mkdir()
        (self.prefix / "versions").symlink_to(real_ver)

        got = self.run_list([])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, f"Nothing is installed in {self.prefix}.\n")

    def test_json_reports_missing_on_node_when_node_target_has_no_tree(self):
        tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen2"
        (tree / "software" / "Demo" / "1.0").mkdir(parents=True)
        mod = tree / "modules" / "all" / "Demo" / "1.0.lua"
        mod.parent.mkdir(parents=True)
        mod.write_text("-- demo\n", encoding="utf-8")

        missing_cli = self.run_list(["--missing"], EESSI_VERSION="2026.06", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(missing_cli.returncode, 0, missing_cli.stderr)
        self.assertEqual(missing_cli.stdout, "Demo/1.0\n")

        doc_run = self.run_list(["--json"], EESSI_VERSION="2026.06", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(doc_run.returncode, 0, doc_run.stderr)
        doc = json.loads(doc_run.stdout)
        self.assertEqual(doc["node_target"], "x86_64/amd/zen4")
        self.assertEqual(doc["missing_on_node"], ["Demo/1.0"])
        self.assertIn("Nothing is built for this node's target, x86_64/amd/zen4, yet", doc["hint"])


if __name__ == "__main__":
    unittest.main()
