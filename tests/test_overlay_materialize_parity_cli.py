#!/usr/bin/env python3
"""Non-regular file and dry-run target validation parity in `eb-local overlay materialize`."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.ZIG, "overlay materialize is a feature of the Zig build")
class OverlayMaterializeParity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-overlay-parity-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.base_bytes = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
        self.digest = hashlib.sha256(self.base_bytes).hexdigest()
        self.base = self.root / "base.eb"
        self.base.write_bytes(self.base_bytes)
        self.overlay = self.root / "site.overlay.toml"
        self.overlay.write_text(
            f'overlay_version = 1\nbase_digest = "{self.digest}"\n',
            encoding="utf-8",
        )

    def run_overlay(self, args, *, timeout=2.0):
        return subprocess.run(
            [binary.ZIG, "overlay", "materialize", *args],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def test_fifo_inputs_and_outputs_refuse_without_blocking(self):
        fifo_overlay = self.root / "fifo.overlay.toml"
        os.mkfifo(fifo_overlay)
        got_ov = self.run_overlay(["--overlay", str(fifo_overlay), "--base", str(self.base)])
        self.assertEqual(got_ov.returncode, 2, got_ov.stdout + got_ov.stderr)
        self.assertEqual(got_ov.stdout, "")
        self.assertIn(f"eb-local: cannot read {fifo_overlay}: NotRegularFile", got_ov.stderr)

        fifo_base = self.root / "fifo.eb"
        os.mkfifo(fifo_base)
        got_base = self.run_overlay(["--overlay", str(self.overlay), "--base", str(fifo_base)])
        self.assertEqual(got_base.returncode, 2, got_base.stdout + got_base.stderr)
        self.assertEqual(got_base.stdout, "")
        self.assertIn(f"eb-local: cannot read {fifo_base}: NotRegularFile", got_base.stderr)

        out_dir = self.root / "fifo-out"
        out_dir.mkdir()
        fifo_recipe = out_dir / "materialized-base.eb"
        os.mkfifo(fifo_recipe)
        got_check = self.run_overlay(
            ["--overlay", str(self.overlay), "--base", str(self.base), "--out-dir", str(out_dir), "--check"]
        )
        self.assertEqual(got_check.returncode, 2, got_check.stdout + got_check.stderr)
        self.assertEqual(got_check.stdout, "")
        self.assertIn(f"eb-local: cannot read {fifo_recipe}: NotRegularFile", got_check.stderr)

        got_write = self.run_overlay(
            ["--overlay", str(self.overlay), "--base", str(self.base), "--out-dir", str(out_dir)]
        )
        self.assertEqual(got_write.returncode, 1, got_write.stdout + got_write.stderr)
        self.assertEqual(got_write.stdout, "")
        self.assertIn(f"eb-local: cannot write {fifo_recipe}:", got_write.stderr)

    def test_dry_run_validates_symlink_and_non_directory_outputs_with_exit_two(self):
        sym_dir = self.root / "sym-out"
        sym_dir.mkdir()
        keep = self.root / "keep.txt"
        keep.write_text("keep\n", encoding="utf-8")
        sym_recipe = sym_dir / "materialized-base.eb"
        sym_recipe.symlink_to(keep)

        got_sym = self.run_overlay(
            ["--overlay", str(self.overlay), "--base", str(self.base), "--out-dir", str(sym_dir), "--dry-run"]
        )
        self.assertEqual(got_sym.returncode, 2, got_sym.stdout + got_sym.stderr)
        self.assertEqual(got_sym.stdout, "")
        self.assertEqual(got_sym.stderr, f"eb-local: cannot read {sym_recipe}: symlink is not followed\n")
        self.assertEqual(keep.read_text(encoding="utf-8"), "keep\n")

        not_dir = self.root / "not-a-dir"
        not_dir.write_text("file\n", encoding="utf-8")
        got_nd = self.run_overlay(
            ["--overlay", str(self.overlay), "--base", str(self.base), "--out-dir", str(not_dir), "--dry-run"]
        )
        self.assertEqual(got_nd.returncode, 2, got_nd.stdout + got_nd.stderr)
        self.assertEqual(got_nd.stdout, "")
        self.assertIn("eb-local: cannot write", got_nd.stderr)


if __name__ == "__main__":
    unittest.main()
