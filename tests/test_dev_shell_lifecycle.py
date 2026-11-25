"""Lifecycle checks for shell code printed by ``eb-local dev``."""

import unittest

from support import available_shells, run_shell
from test_storage import StorageFixture


MODULE_WITH_TARGET = r"""
module() {
    if [ "$1" = load ]; then
        case "$2" in
            EESSI/*)
                export EESSI_VERSION=2026.06
                export EESSI_SOFTWARE_SUBDIR=x86_64/generic
                export EESSI_ACCELERATOR_TARGET=
                ;;
        esac
    fi
}
"""


class DevShellLifecycle(StorageFixture):
    """Exercise successive dev-shell changes in the same caller."""

    def setUp(self):
        super().setUp()
        self.prefix.mkdir(parents=True)

    def test_a_later_dev_drops_an_earlier_wrapper_directory(self):
        emitted = self.run_wrapper(["dev"])
        self.assertEqual(emitted.returncode, 0, emitted.stderr)

        stale = self.root / "stale wrappers"
        stale.mkdir()
        clean = self.root / "clean-bin"
        clean.mkdir()
        for name, executable in available_shells():
            with self.subTest(shell=name):
                path_file = self.root / f"path-{name}"
                wrapper_file = self.root / f"wrapper-{name}"
                script = (
                    MODULE_WITH_TARGET
                    + f"\nexport EB_LOCAL_RPATH_WRAPPERS={str(stale)!r}\n"
                    + f"export PATH={str(stale)!r}:{str(clean)!r}\n"
                    + emitted.stdout
                    + f"\nprintf '%s' \"$PATH\" > {str(path_file)!r}\n"
                    + f"printf '%s' \"${{EB_LOCAL_RPATH_WRAPPERS-unset}}\" > {str(wrapper_file)!r}\n"
                )
                replay = run_shell(
                    name,
                    executable,
                    script,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
                self.assertNotIn(str(stale), path_file.read_text().split(":"))
                self.assertEqual(wrapper_file.read_text(), "unset")


if __name__ == "__main__":
    unittest.main()
