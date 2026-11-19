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

GUARD = r"""#!/bin/sh
printf '%s\n' 'export EESSI_SOFTWARE_SUBDIR=wrong/from-failed-guard'
exit 78
"""

MODULE_WITHOUT_TARGET = "module() { :; }\n"


class DevShellLifecycle(StorageFixture):
    """Exercise successive dev-shell changes in the same caller."""

    def setUp(self):
        super().setUp()
        self.prefix.mkdir(parents=True)

    def test_failed_arch_guard_stops_eval_under_errexit(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        guard = bin_dir / "eessi-arch-guard"
        guard.write_text(GUARD)
        guard.chmod(0o755)
        emitted = self.run_wrapper(["dev"], PATH=f"{bin_dir}:/usr/bin:/bin")
        self.assertEqual(emitted.returncode, 0, emitted.stderr)

        for name, executable in available_shells():
            with self.subTest(shell=name):
                reached = self.root / f"reached-{name}"
                script = (
                    MODULE_WITH_TARGET
                    + "\nset -e\n"
                    + emitted.stdout
                    + f"\nprintf '%s\\n' reached > {str(reached)!r}\n"
                )
                replay = run_shell(
                    name,
                    executable,
                    script,
                    env=dict(self.env, PATH=f"{bin_dir}:/usr/bin:/bin"),
                    cwd=self.root,
                )
                self.assertEqual(replay.returncode, 78, replay.stdout + replay.stderr)
                self.assertFalse(reached.exists())

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

    def test_nounset_dev_names_the_selected_target_prefix(self):
        emitted = self.run_wrapper(["dev"])
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        expected = self.prefix / "dev" / "2026.06" / "x86_64" / "generic"

        for name, executable in available_shells():
            with self.subTest(shell=name):
                replay = run_shell(
                    name,
                    executable,
                    MODULE_WITH_TARGET
                    + "\nset -u\n"
                    + emitted.stdout
                    + "\nprintf '%s\\n' \"$EB_LOCAL_DEV_PREFIX\"\n",
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
                self.assertEqual(replay.stdout.strip(), str(expected))

    def test_nounset_dev_reports_a_missing_target_without_expanding_it(self):
        emitted = self.run_wrapper(["dev"])
        self.assertEqual(emitted.returncode, 0, emitted.stderr)

        for name, executable in available_shells():
            with self.subTest(shell=name):
                replay = run_shell(
                    name,
                    executable,
                    MODULE_WITHOUT_TARGET + "\nset -u\n" + emitted.stdout,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(replay.returncode, 1, replay.stdout + replay.stderr)
                self.assertIn("the EESSI module set no software target", replay.stderr)
                self.assertNotIn("unbound variable", replay.stderr)
                self.assertNotIn("parameter not set", replay.stderr)


if __name__ == "__main__":
    unittest.main()
