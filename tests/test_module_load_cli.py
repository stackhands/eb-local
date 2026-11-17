#!/usr/bin/env python3
"""A module load in a build, through the command line of the Zig build.

Lmod writes a module's messages to stderr as it loads, and its reason when
a load fails: a build shows only the reason.
"""
import unittest

import binary
from test_storage import StorageFixture

# The module double, chattering on stderr as Lmod does, and failing to load
# CONTROL_LOAD_FAILS with Lmod's message for a module it cannot find.
LOAD = r'''
eval "double_$(declare -f module)"
module() {
    if [ "$1" = load ]; then
        if [ "$2" = "${CONTROL_LOAD_FAILS:-}" ]; then
            echo "Lmod has detected the following error: The following module(s) are unknown: \"$2\"" >&2
            echo "    module --ignore_cache load \"$2\"" >&2
            return 1
        fi
        echo "Module for $2 loaded successfully" >&2
    fi
    double_module "$@"
}
export -f module double_module
'''


@unittest.skipUnless(binary.BIN, "showing why a load failed is a feature of the Zig build")
class ModuleLoad(StorageFixture):
    def setUp(self):
        super().setUp()
        with open(self.root / "doubles.sh", "a") as handle:
            handle.write(LOAD)

    def test_a_load_that_works_stays_quiet(self):
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("loaded successfully", run.stdout + run.stderr)

    def test_a_failed_load_says_why(self):
        for module in ("EESSI/2026.06", "EESSI-extend/2026.06-easybuild"):
            with self.subTest(module=module):
                run = self.run_wrapper(CONTROL_LOAD_FAILS=module)
                self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                self.assertIn(f"eb-local: could not load {module}:\n"
                              "  Lmod has detected the following error: The following module(s) are unknown: "
                              f"\"{module}\"\n"
                              f"      module --ignore_cache load \"{module}\"\n", run.stderr)
                self.assertNotIn("loaded successfully", run.stderr)
                self.assertFalse((self.root / "eb.json").exists())


if __name__ == "__main__":
    unittest.main()
