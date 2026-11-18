#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local restore`."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "restore is a feature of the Zig build")
class RestoreCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-restore-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.versions = self.prefix / "versions"
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def run_restore(self, args, path=None):
        return subprocess.run(
            [binary.BIN, "restore", *args],
            env={
                "PATH": path or f"{self.bin}:/usr/bin:/bin",
                "HOME": str(self.root),
                "EB_LOCAL_CONFIG": "",
                "EB_LOCAL_PREFIX": str(self.prefix),
            },
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def install_rtrash(self, list_json="[]", list_rc=0, restore_rc=0, log_file=None):
        rtrash = self.bin / "rtrash"
        log_stmt = f'printf "%s\\n" "$*" >> "{log_file}"\n' if log_file else ""
        rtrash.write_text(
            "#!/bin/sh\n"
            f"{log_stmt}"
            'if [ "$1" = "list" ]; then\n'
            f"  printf '%s\\n' '{list_json}'\n"
            f"  exit {list_rc}\n"
            "fi\n"
            f"exit {restore_rc}\n",
            encoding="utf-8",
        )
        rtrash.chmod(0o755)

    def test_missing_args_prefix_or_rtrash_and_symlinked_versions_exit_two(self):
        no_args = self.run_restore([])
        self.assertEqual(no_args.returncode, 2, no_args.stdout + no_args.stderr)
        self.assertIn("restore needs NAME/VERSION", no_args.stderr)

        no_ver_dir = self.run_restore(["Demo/1.0"])
        self.assertEqual(no_ver_dir.returncode, 2, no_ver_dir.stdout + no_ver_dir.stderr)
        self.assertIn("nothing was installed in", no_ver_dir.stderr)

        real_ver = self.root / "real-versions"
        real_ver.mkdir()
        self.prefix.mkdir()
        self.versions.symlink_to(real_ver)
        sym = self.run_restore(["Demo/1.0"])
        self.assertEqual(sym.returncode, 2, sym.stdout + sym.stderr)
        self.assertIn("reached through a symbolic link", sym.stderr)

        self.versions.unlink()
        self.versions.mkdir()
        no_bin = self.run_restore(["Demo/1.0"], path="/nonexistent")
        self.assertEqual(no_bin.returncode, 2, no_bin.stdout + no_bin.stderr)
        self.assertIn("rtrash is not on PATH", no_bin.stderr)

    def test_invalid_module_names_and_rtrash_list_failures_exit_two(self):
        self.versions.mkdir(parents=True)
        self.install_rtrash(list_json="[]", list_rc=0)
        for bad in ("Demo", "Demo/1.0/2", "../1.0"):
            with self.subTest(bad=bad):
                got = self.run_restore([bad])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)

        self.install_rtrash(list_json="not-json", list_rc=0)
        bad_json = self.run_restore(["Demo/1.0"])
        self.assertEqual(bad_json.returncode, 2, bad_json.stdout + bad_json.stderr)
        self.assertIn("cannot read what rtrash list --json printed", bad_json.stderr)

        self.install_rtrash(list_json="[]", list_rc=3)
        bad_rc = self.run_restore(["Demo/1.0"])
        self.assertEqual(bad_rc.returncode, 2, bad_rc.stdout + bad_rc.stderr)
        self.assertIn("rtrash list --json exited 3", bad_rc.stderr)

    def test_dry_run_and_existing_destination_guard(self):
        tree = self.versions / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (tree / "software").mkdir(parents=True)
        (tree / "modules" / "all").mkdir(parents=True)
        inst = tree / "software" / "Demo" / "1.0"
        mod = tree / "modules" / "all" / "Demo" / "1.0.lua"
        calls = self.root / "rtrash.log"
        payload = json.dumps(
            [
                {"original": str(inst), "trash_dir": "/tmp/trash"},
                {"original": str(mod), "trash_dir": "/tmp/trash"},
            ]
        )
        self.install_rtrash(list_json=payload, log_file=calls)

        dry = self.run_restore(["--dry-run", "Demo/1.0"])
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertIn(f"{inst}/", dry.stdout)
        self.assertIn(str(mod), dry.stdout)
        self.assertIn("dry run, nothing restored", dry.stdout)
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["list --json"])

        inst.mkdir(parents=True)
        calls.unlink()
        exists_err = self.run_restore(["Demo/1.0"])
        self.assertEqual(exists_err.returncode, 2, exists_err.stdout + exists_err.stderr)
        self.assertIn("exists; restore replaces nothing", exists_err.stderr)
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["list --json"])

    def test_duplicate_trash_entries_exit_two_without_invoking_restore(self):
        tree = self.versions / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (tree / "software").mkdir(parents=True)
        (tree / "modules" / "all").mkdir(parents=True)
        inst = tree / "software" / "Demo" / "1.0"
        mod = tree / "modules" / "all" / "Demo" / "1.0.lua"
        calls = self.root / "rtrash-dup.log"
        payload = json.dumps(
            [
                {"original": str(inst), "trash_dir": "/tmp/trash/1"},
                {"original": str(inst), "trash_dir": "/tmp/trash/2"},
                {"original": str(mod), "trash_dir": "/tmp/trash/1"},
            ]
        )
        self.install_rtrash(list_json=payload, log_file=calls)

        dup = self.run_restore(["Demo/1.0"])
        self.assertEqual(dup.returncode, 2, dup.stdout + dup.stderr)
        self.assertEqual(dup.stdout, "")
        self.assertIn("is in the trash more than once; restore the one you want with: rtrash restore", dup.stderr)
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["list --json"])


if __name__ == "__main__":
    unittest.main()
