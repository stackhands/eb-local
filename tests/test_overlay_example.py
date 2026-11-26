#!/usr/bin/env python3
"""Verify the shipped examples/overlays/OpenMPI.site.overlay.toml materializes unchanged."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary

REPO = Path(__file__).resolve().parents[1]
EXAMPLE = REPO / "examples" / "overlays" / "OpenMPI.site.overlay.toml"


@unittest.skipUnless(binary.ZIG, "overlay materialize is a feature of the Zig build")
class OverlayExampleTests(unittest.TestCase):
    def test_shipped_openmpi_example_overlay_materializes_with_matching_digest(self):
        with tempfile.TemporaryDirectory(prefix="eb-local-overlay-ex-") as td:
            root = Path(td)
            base = root / "OpenMPI-4.1.6-GCC-13.3.0.eb"
            base.write_text("preconfigopts = '--with-pmi=pmix'\n", encoding="utf-8")
            digest = hashlib.sha256(base.read_bytes()).hexdigest()

            overlay = root / "OpenMPI.site.overlay.toml"
            text = EXAMPLE.read_text(encoding="utf-8").replace(
                "replace-with-sha256sum-of-the-upstream-easyconfig",
                digest,
            )
            overlay.write_text(text, encoding="utf-8")

            run = subprocess.run(
                [binary.ZIG, "overlay", "materialize", "--overlay", str(overlay), "--base", str(base), "--dry-run"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("would write", run.stdout)


if __name__ == "__main__":
    unittest.main()
