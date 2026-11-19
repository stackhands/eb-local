#!/usr/bin/env python3
"""TOML decimal integers may group digits with a single underscore."""
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(binary.BIN, "TOML configuration is a feature of the Zig build")
class TomlInteger(StorageFixture):
    def setUp(self):
        super().setUp()
        self.env["LC_ALL"] = "C.UTF-8"
        self.env["LANG"] = "C.UTF-8"

    def read_days(self, text):
        path = self.root / "days.toml"
        path.write_text(text)
        path.chmod(0o644)
        return self.run_wrapper(["config", "--config", str(path), "--get", "clean.logs_older_than_days"])

    def test_a_toml_integer_groups_digits_with_underscores(self):
        run = self.read_days("[clean]\nlogs_older_than_days = 1_000\n")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "1000\n")

    def test_a_doubled_underscore_is_not_a_toml_integer(self):
        run = self.read_days("[clean]\nlogs_older_than_days = 1__000\n")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("is not a value", run.stderr)


if __name__ == "__main__":
    unittest.main()
