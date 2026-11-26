#!/usr/bin/env python3
"""`eb-local modulerc` writes only operator-selected Lmod directives."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary
import hostile_fs


def run(args, *, text=True):
    return subprocess.run(
        [binary.ZIG, "modulerc", *args],
        capture_output=True,
        text=text,
    )


@unittest.skipUnless(binary.ZIG, "needs the Zig build")
class Modulerc(unittest.TestCase):
    def test_default_output_and_status_are_unchanged_raw_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            control = tree / ".modulerc.lua"
            args = [
                "--module-tree",
                str(tree),
                "--default",
                "Example/2.0",
            ]

            check_drift = run([*args, "--check"], text=False)
            self.assertEqual(
                (check_drift.returncode, check_drift.stdout, check_drift.stderr),
                (1, f"would update {control}\n".encode(), b""),
            )

            dry = run([*args, "--dry-run"], text=False)
            self.assertEqual(
                (dry.returncode, dry.stdout, dry.stderr),
                (0, b'module_version("Example/2.0", "default")\n', b""),
            )

            got = run(args, text=False)
            self.assertEqual(
                (got.returncode, got.stdout, got.stderr),
                (0, f"wrote {control}\n".encode(), b""),
            )

            check_ok = run([*args, "--check"], text=False)
            self.assertEqual(
                (check_ok.returncode, check_ok.stdout, check_ok.stderr),
                (0, f"up to date {control}\n".encode(), b""),
            )

    def test_check_reports_drift_without_creating_the_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            control = tree / ".modulerc.lua"
            args = [
                "--module-tree",
                str(tree),
                "--default",
                "Example/2.0",
            ]
            drift = run([*args, "--check"])
            self.assertEqual(
                (drift.returncode, drift.stdout, drift.stderr),
                (1, f"would update {control}\n", ""),
            )
            self.assertFalse(tree.exists())

            written = run(args)
            self.assertEqual(written.returncode, 0, written.stderr)
            before = (control.read_bytes(), control.stat().st_mtime_ns)
            current = run([*args, "--check"])
            self.assertEqual(
                (current.returncode, current.stdout, current.stderr),
                (0, f"up to date {control}\n", ""),
            )
            self.assertEqual(
                (control.read_bytes(), control.stat().st_mtime_ns),
                before,
            )

    def test_writes_and_idempotently_updates_the_module_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            tree.mkdir()
            control = tree / ".modulerc.lua"
            control.write_text("-- an operator comment\n")
            args = [
                "--module-tree",
                str(tree),
                "--default",
                "Example/2.0",
                "--alias",
                "Example/latest=Example/2.0",
                "--hide",
                "Example/1.0",
            ]
            first = run(args)
            self.assertEqual(first.returncode, 0, first.stderr)
            expected = (
                "-- an operator comment\n"
                'module_version("Example/2.0", "default")\n'
                'module_alias("Example/latest", "Example/2.0")\n'
                'hide_version("Example/1.0")\n'
            )
            self.assertEqual(control.read_text(), expected)
            before = control.read_bytes()
            second = run(args)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(control.read_bytes(), before)

            modulecmd = shutil.which("modulecmd")
            if modulecmd:
                checked = subprocess.run(
                    [modulecmd, "bash", "avail"],
                    env={**os.environ, "MODULEPATH": str(tree)},
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_dry_run_prints_the_complete_file_without_writing_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            tree.mkdir()
            control = tree / ".modulerc.lua"
            control.write_text('hide_version("Old/1.0")\n')
            got = run(
                [
                    "--module-tree",
                    str(tree),
                    "--default",
                    "New/2.0",
                    "--dry-run",
                ]
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual(
                got.stdout,
                'hide_version("Old/1.0")\n'
                'module_version("New/2.0", "default")\n',
            )
            self.assertEqual(control.read_text(), 'hide_version("Old/1.0")\n')

    def test_check_and_dry_run_are_alternatives(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = run(
                [
                    "--module-tree",
                    tmp,
                    "--default",
                    "Example/2.0",
                    "--dry-run",
                    "--check",
                ]
            )
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            self.assertEqual(got.stdout, "")
            self.assertEqual(
                got.stderr,
                "eb-local: modulerc takes --dry-run or --check, not both\n",
            )
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_invalid_module_names_are_rejected_with_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad_cases = (
                ["--default", "foo bar"],
                ["--default", "../escape"],
                ["--hide", "Example/1.0/"],
                ["--alias", "bad name=Example/2.0"],
                ["--alias", "latest=Example 2.0"],
            )
            for extra in bad_cases:
                with self.subTest(extra=extra):
                    got = run(["--module-tree", tmp, *extra])
                    self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                    self.assertEqual(got.stdout, "")
                    self.assertIn("is not a module name", got.stderr)
            self.assertFalse((Path(tmp) / ".modulerc.lua").exists())

    def test_never_selects_a_default_without_one_on_the_command_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = run(["--module-tree", tmp, "--hide", "Example/1.0"])
            self.assertEqual(got.returncode, 0, got.stderr)
            text = (Path(tmp) / ".modulerc.lua").read_text()
            self.assertEqual(text, 'hide_version("Example/1.0")\n')
            self.assertNotIn("module_version", text)

    def test_unreadable_existing_modulerc_exits_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".modulerc.lua").mkdir()
            got = run(["--module-tree", tmp, "--default", "Example/2.0", "--check"])
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            self.assertEqual(got.stdout, "")
            self.assertIn("eb-local: cannot read ", got.stderr)

    def test_refuses_to_replace_symlink_and_leaves_no_temp_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "outside.lua"
            target.write_text("-- external\n", encoding="utf-8")
            tree = root / "modules"
            tree.mkdir()
            control = tree / ".modulerc.lua"
            control.symlink_to(target)

            got = run(["--module-tree", str(tree), "--default", "Example/2.0"])
            self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
            self.assertIn("symlink", got.stderr)
            self.assertTrue(control.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "-- external\n")
            self.assertEqual(sorted(p.name for p in tree.iterdir()), [".modulerc.lua"])

            for flag in ("--check", "--dry-run"):
                with self.subTest(flag=flag):
                    ro = run(["--module-tree", str(tree), "--default", "Example/2.0", flag])
                    self.assertEqual(ro.returncode, 2, ro.stdout + ro.stderr)
                    self.assertEqual(ro.stdout, "")
                    self.assertIn("symlink", ro.stderr)

    def test_hostile_write_destinations_fail_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)

            ro_tree = root / "ro-tree"
            ro_tree.mkdir()
            with hostile_fs.readonly_dir(ro_tree):
                ro_got = run(["--module-tree", str(ro_tree), "--default", "Example/2.0"])
                self.assertEqual(ro_got.returncode, 1, ro_got.stdout + ro_got.stderr)
                self.assertEqual(ro_got.stdout, "")
                self.assertIn("[Errno 13] Permission denied", ro_got.stderr)
                self.assertNotIn("AccessDenied", ro_got.stderr)

            dir_tree = root / "dir-tree"
            dir_tree.mkdir()
            (dir_tree / ".modulerc.lua").mkdir()
            dir_got = run(["--module-tree", str(dir_tree), "--default", "Example/2.0"])
            self.assertEqual(dir_got.returncode, 2, dir_got.stdout + dir_got.stderr)
            self.assertEqual(dir_got.stdout, "")
            self.assertIn("not a regular file", dir_got.stderr)

            dangling_tree = root / "dangling-tree"
            dangling_tree.mkdir()
            link, outside = hostile_fs.dangling_symlink(dangling_tree / ".modulerc.lua", root / "outside-target.lua")
            w_got = run(["--module-tree", str(dangling_tree), "--default", "Example/2.0"])
            self.assertEqual(w_got.returncode, 1, w_got.stdout + w_got.stderr)
            self.assertIn("symlink", w_got.stderr)
            self.assertTrue(link.is_symlink())
            self.assertFalse(outside.exists())
            for flag in ("--check", "--dry-run"):
                ro = run(["--module-tree", str(dangling_tree), "--default", "Example/2.0", flag])
                self.assertEqual(ro.returncode, 2, ro.stdout + ro.stderr)
                self.assertEqual(ro.stdout, "")
                self.assertIn("symlink", ro.stderr)

    def test_tmpfs_enospc_fails_cleanly(self):
        mnt = hostile_fs.enter_full_tmpfs(self)
        if mnt is None:
            return
        got = run(["--module-tree", str(mnt / "mods"), "--default", "Example/2.0"])
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("[Errno 28] No space left on device", got.stderr)
        self.assertNotIn("NoSpace", got.stderr)


if __name__ == "__main__":
    unittest.main()
