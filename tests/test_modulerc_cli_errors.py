#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local modulerc` validation and JSON idempotency."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "modulerc is a feature of the Zig build")
class ModulercCliErrors(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-modulerc-err-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def run_mrc(self, args):
        return subprocess.run(
            [binary.BIN, "modulerc", *args],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_requires_absolute_module_tree_and_at_least_one_directive(self):
        cases = [
            (["--default", "Example/1.0"], "needs --module-tree DIR"),
            (["--module-tree", "relative/tree", "--default", "Example/1.0"], "is not an absolute path"),
            (["--module-tree", str(self.root / "tree")], "needs at least one --default, --alias or --hide"),
        ]
        for args, needle in cases:
            with self.subTest(args=args):
                got = self.run_mrc(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(needle, got.stderr)

    def test_alias_requires_non_empty_name_and_target_separated_by_equals(self):
        tree = str(self.root / "tree")
        for bad in ("no-equals", "=Example/1.0", "Example/latest="):
            with self.subTest(bad=bad):
                got = self.run_mrc(["--module-tree", tree, "--alias", bad])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("--alias needs NAME=MODULE", got.stderr)

    def test_file_at_module_tree_exits_two_without_modifying_file(self):
        not_dir = self.root / "not-a-dir"
        not_dir.write_text("keep\n", encoding="utf-8")
        for extra in ([], ["--check"], ["--dry-run"], ["--json"]):
            with self.subTest(extra=extra):
                got = self.run_mrc(["--module-tree", str(not_dir), "--default", "Example/1.0", *extra])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("cannot read", got.stderr)
        self.assertEqual(not_dir.read_text(encoding="utf-8"), "keep\n")

    def test_idempotent_write_json_reports_changed_false(self):
        tree = self.root / "mods"
        args = ["--module-tree", str(tree), "--default", "Example/2.0", "--json"]
        first = self.run_mrc(args)
        self.assertEqual(first.returncode, 0, first.stderr)
        doc1 = json.loads(first.stdout)
        self.assertTrue(doc1["changed"])
        self.assertEqual(doc1["mode"], "write")

        second = self.run_mrc(args)
        self.assertEqual(second.returncode, 0, second.stderr)
        doc2 = json.loads(second.stdout)
        self.assertFalse(doc2["changed"])
        self.assertEqual(doc2["mode"], "write")


if __name__ == "__main__":
    unittest.main()
