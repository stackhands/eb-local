#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local clean` filters, age bounds, and refusals."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

import binary


@unittest.skipUnless(binary.BIN, "clean is a feature of the Zig build")
class CleanCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-clean-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"

    def run_clean(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "EB_LOCAL_PREFIX": str(self.prefix),
        }
        env.pop("SLURM_JOB_ID", None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_option_conflicts_bounds_and_explain_refusals(self):
        cases = (
            (["clean", "--no-logs", "--logs-older-than", "7"], "clean takes --no-logs or --logs-older-than, not both"),
            (["clean", "--logs-older-than", "1", "--logs-older-than=2"], "clean takes one --logs-older-than"),
            (["clean", "--logs-older-than", "100000"], "--logs-older-than needs a number of days"),
            (["clean", "--logs-older-than", "abc"], "--logs-older-than needs a number of days"),
            (["clean", "--unknown"], "clean does not know"),
            (["clean", "--workspaces"], "SLURM_JOB_ID is unset or empty"),
            (["--explain", "clean"], "--explain goes with a recipe or with eb"),
        )
        for args, msg in cases:
            with self.subTest(args=args):
                got = self.run_clean(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(msg, got.stderr)

    def test_trash_rtrash_without_rtrash_on_path_exits_two(self):
        got = self.run_clean(["clean"], EB_LOCAL_TRASH="rtrash")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("clean.trash is rtrash, but rtrash is not on PATH", got.stderr)

    def test_sources_delete_prunes_empty_subdirs_and_keeps_sources_root(self):
        src = self.prefix / ".eb-local" / "sources" / "p" / "pigz" / "pigz-2.8.tar.gz"
        src.parent.mkdir(parents=True)
        src.write_text("archive", encoding="utf-8")

        got = self.run_clean(["clean", "--no-logs", "--sources", "--delete", "--json"])
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        doc = json.loads(got.stdout)
        self.assertEqual(doc["action"], "deleted")
        self.assertEqual(doc["removed_items"], 1)
        self.assertEqual(doc["items"], [{"path": str(src), "kind": "file"}])
        self.assertFalse(src.exists())
        self.assertFalse((self.prefix / ".eb-local" / "sources" / "p").exists())
        self.assertTrue((self.prefix / ".eb-local" / "sources").is_dir())

    def test_aged_directory_protected_by_fresh_inner_file_and_symlinked_eb_local_refused(self):
        logs = self.prefix / ".eb-local" / "logs"
        reprod = logs / "reprod_1"
        reprod.mkdir(parents=True)
        inner = reprod / "fresh.log"
        inner.write_text("fresh\n", encoding="utf-8")
        old = time.time() - 5 * 86400
        os.utime(reprod, (old, old))

        kept = self.run_clean(["clean", "--logs-older-than=0", "--delete", "--json"])
        self.assertEqual(kept.returncode, 0, kept.stdout + kept.stderr)
        self.assertEqual(json.loads(kept.stdout)["action"], "nothing")
        self.assertTrue(inner.exists())

        os.utime(inner, (old, old))
        os.utime(reprod, (old, old))
        removed = self.run_clean(["clean", "--logs-older-than=0", "--delete", "--json"])
        self.assertEqual(removed.returncode, 0, removed.stdout + removed.stderr)
        doc = json.loads(removed.stdout)
        self.assertEqual(doc["action"], "deleted")
        self.assertEqual(doc["items"], [{"path": str(reprod), "kind": "dir"}])
        self.assertFalse(reprod.exists())

        sym_prefix = self.root / "sym-prefix"
        sym_prefix.mkdir()
        real_eb = self.root / "real-eb"
        (real_eb / "logs").mkdir(parents=True)
        (sym_prefix / ".eb-local").symlink_to(real_eb)
        refused = self.run_clean(["clean"], EB_LOCAL_PREFIX=str(sym_prefix))
        self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertIn("not to a directory inside the install prefix", refused.stderr)

    def test_rtrash_put_failure_reports_exit_code_and_preserves_target(self):
        src = self.prefix / ".eb-local" / "sources" / "p" / "pkg.tar.gz"
        src.parent.mkdir(parents=True)
        src.write_text("keep\n", encoding="utf-8")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        rtrash = bin_dir / "rtrash"
        rtrash.write_text("#!/bin/sh\necho 'trash unavailable' >&2\nexit 7\n", encoding="utf-8")
        rtrash.chmod(0o755)

        got = self.run_clean(["clean", "--no-logs", "--sources"], PATH=f"{bin_dir}:/usr/bin:/bin")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("rtrash put exited 7", got.stderr)
        self.assertTrue(src.exists())


if __name__ == "__main__":
    unittest.main()
