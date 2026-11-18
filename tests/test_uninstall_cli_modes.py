#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local uninstall` options, `--delete`, and refusals."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "uninstall is a feature of the Zig build")
class UninstallCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-uninstall-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def seed_module(self, target, name, ver):
        base = self.prefix / "versions" / "2026.06" / "software" / "linux" / target
        inst = base / "software" / name / ver
        (inst / "bin").mkdir(parents=True)
        (inst / "bin" / name).write_text("bin\n", encoding="utf-8")
        mod = base / "modules" / "all" / name / f"{ver}.lua"
        mod.parent.mkdir(parents=True)
        mod.write_text("-- lua\n", encoding="utf-8")
        return inst, mod

    def run_uninstall(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "EB_LOCAL_PREFIX": str(self.prefix),
        }
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_option_validation_and_explain_refusals(self):
        self.seed_module("x86_64/amd/zen4", "pigz", "2.8")
        cases = (
            (["uninstall"], "uninstall needs NAME/VERSION"),
            (["uninstall", "pigz"], "has no version"),
            (["uninstall", "pigz/2.8/extra"], "has more parts"),
            (["uninstall", "bad;name/2.8"], "is not a module name"),
            (["uninstall", "--unknown-flag", "pigz/2.8"], "uninstall does not know"),
            (["uninstall", "--target", "zen4", "--target=zen4", "pigz/2.8"], "uninstall takes one --target"),
            (["uninstall", "--usage-log", "a", "--usage-log=b", "pigz/2.8"], "uninstall takes one --usage-log"),
            (["--explain", "uninstall", "pigz/2.8"], "--explain goes with a recipe or with eb"),
        )
        for args, msg in cases:
            with self.subTest(args=args):
                got = self.run_uninstall(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(msg, got.stderr)

    def test_trash_rtrash_without_rtrash_on_path_exits_two(self):
        self.seed_module("x86_64/amd/zen4", "pigz", "2.8")
        got = self.run_uninstall(["uninstall", "pigz/2.8"], EB_LOCAL_TRASH="rtrash")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("clean.trash is rtrash, but rtrash is not on PATH", got.stderr)

    def test_delete_with_joined_target_trailing_slash_prunes_empty_dirs(self):
        zen2_inst, zen2_mod = self.seed_module("x86_64/amd/zen2", "pigz", "2.8")
        zen4_inst, zen4_mod = self.seed_module("x86_64/amd/zen4", "pigz", "2.8")
        (zen2_inst / "bin" / "pigz").chmod(0o444)
        (zen2_inst / "bin").chmod(0o555)
        zen2_inst.chmod(0o555)

        got = self.run_uninstall(["uninstall", "--target=x86_64/amd/zen2/", "--delete", "pigz/2.8"])
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("deleted 1 installation(s) and 1 module file(s)", got.stdout)
        self.assertFalse(zen2_inst.exists())
        self.assertFalse(zen2_inst.parent.exists())
        self.assertFalse(zen2_mod.exists())
        self.assertFalse(zen2_mod.parent.exists())
        self.assertTrue(zen4_inst.exists())
        self.assertTrue(zen4_mod.exists())

    def test_joined_usage_log_flag_blocks_when_keep_logs_exits_two(self):
        inst, mod = self.seed_module("x86_64/amd/zen4", "pigz", "2.8")
        keep = self.bin / "eb-keep-logs"
        keep.write_text("#!/bin/sh\necho 'busy log' >&2\nexit 2\n", encoding="utf-8")
        keep.chmod(0o755)
        log_file = self.root / "usage.log"
        log_file.write_text("used\n", encoding="utf-8")

        got = self.run_uninstall(
            ["uninstall", f"--usage-log={log_file}", "--delete", "pigz/2.8"],
            PATH=f"{self.bin}:/usr/bin:/bin",
        )
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("busy log", got.stderr)
        self.assertTrue(inst.exists())
        self.assertTrue(mod.exists())


if __name__ == "__main__":
    unittest.main()
