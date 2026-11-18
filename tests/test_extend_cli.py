#!/usr/bin/env python3
"""eb-local eb and eb-local --explain eb, through the command line of the Zig build.

A fake EESSI repository holds an init whose module function sets what
EESSI-extend sets when it loads; the eb double prints the process umask,
its arguments and the variables it got, and leaves a mark that it ran.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

import binary

SCRIPT = Path(__file__).resolve().parents[1] / "eb-local"
INIT = r'''
export EESSI_SOFTWARE_PATH="$EESSI_CVMFS_REPO/versions/2026.06/software/linux/x86_64/amd/zen4"
export EESSI_SITE_SOFTWARE_PATH="$EESSI_CVMFS_REPO/host_injections/2026.06/software/linux/x86_64/amd/zen4"
module() {
    if [ "$1" = load ]; then
        export EASYBUILD_PREFIX="${WORKING_DIR:-/tmp/$USER}/easybuild"
        if [ -n "${EESSI_CVMFS_INSTALL+set}" ]; then installpath=$EESSI_SOFTWARE_PATH
        elif [ -n "${EESSI_SITE_INSTALL+set}" ]; then installpath=$EESSI_SITE_SOFTWARE_PATH
        else installpath="${EESSI_USER_INSTALL:-${EESSI_PROJECT_INSTALL:-$HOME/eessi}}/versions/2026.06/software/linux/x86_64/amd/zen4"
        fi
        export EASYBUILD_INSTALLPATH="${CONTROL_INSTALLPATH:-$installpath}"
    fi
}
'''
EB = r'''#!/bin/sh
touch "$CONTROL_ROOT/eb-ran"
umask
printf '%s\n' "$@" "EASYBUILD_PREFIX=$EASYBUILD_PREFIX" "EESSI_USER_INSTALL=${EESSI_USER_INSTALL-unset}"
'''

SLOW_EB = r'''#!/bin/sh
exec python3 -c '
import os, signal, sys, time
got = []
signal.signal(signal.SIGTERM, lambda sig, frame: got.append(sig))
open(os.environ["CONTROL_ROOT"] + "/eb.pid", "w").write(str(os.getpid()))
deadline = time.monotonic() + 10
while not got and time.monotonic() < deadline:
    time.sleep(0.05)
open(os.environ["CONTROL_ROOT"] + "/eb.signals", "w").write(str(len(got)))
sys.exit(15 if got else 0)
'
'''


@unittest.skipUnless(binary.BIN, "eb and --explain eb are features of the Zig build")
class ExtendCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-extend-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init.parent.mkdir(parents=True)
        init.write_text(INIT)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "eb").write_text(EB)
        (bin_dir / "eb").chmod(0o755)
        (self.root / "home").mkdir()
        self.env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(self.root / "home"), "USER": "alice",
                    "EESSI_CVMFS_REPO": str(self.root / "repo"), "CONTROL_ROOT": str(self.root)}

    def run_tool(self, args, **extra):
        argv, env = binary.command(SCRIPT, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_a_sigterm_to_eb_local_eb_reaches_easybuild(self):
        (self.root / "bin" / "eb").write_text(SLOW_EB)
        argv, env = binary.command(SCRIPT, ["eb", "x.eb"], self.env)
        launcher = subprocess.Popen(argv, env=env, cwd=self.root, start_new_session=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: launcher.poll() is None and os.killpg(launcher.pid, 9))
        pid_file = self.root / "eb.pid"
        deadline = time.monotonic() + 20
        while not pid_file.exists():
            self.assertLess(time.monotonic(), deadline, "eb did not start")
            time.sleep(0.05)
        sent = time.monotonic()
        os.kill(launcher.pid, 15)
        out, err = launcher.communicate(timeout=30)
        self.assertLess(time.monotonic() - sent, 8, out + err)
        self.assertEqual(launcher.returncode, -15, out + err)
        self.assertEqual((self.root / "eb.signals").read_text(), "1")

    def test_explain_eb_prints_the_launcher_script_and_runs_nothing(self):
        mine = self.root / "mine"
        run = self.run_tool(["--explain", "eb", "--", "my recipe.eb", "--robot"], EESSI_USER_INSTALL=str(mine))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"# EESSI_USER_INSTALL={mine} selects a user install; the process umask is 077.", run.stdout)
        self.assertIn("\nset -- 077 user 'my recipe.eb' --robot\n", run.stdout)
        self.assertIn("\nmodule load EESSI-extend\n", run.stdout)
        self.assertEqual(run.stdout.rstrip().splitlines()[-1], 'exec eb "$@"')
        self.assertFalse(mine.exists())
        self.assertFalse((self.root / "eb-ran").exists())
        run = self.run_tool(["--explain", "eb", "x.eb"])
        self.assertIn("No install variable is set: a user install into the module's default, $HOME/eessi", run.stdout)

    def test_the_printed_script_runs_as_eb_local_eb_does(self):
        mine = self.root / "mine"
        explained = self.run_tool(["--explain", "eb", "--", "my recipe.eb", "--robot"], EESSI_USER_INSTALL=str(mine))
        self.assertEqual(explained.returncode, 0, explained.stderr)
        real = self.run_tool(["eb", "--", "my recipe.eb", "--robot"], EESSI_USER_INSTALL=str(mine))
        self.assertEqual(real.returncode, 0, real.stderr)
        self.assertTrue((self.root / "eb-ran").exists())
        replay = subprocess.run(["bash", "--noprofile", "--norc", "-c", explained.stdout],
                                env=dict(self.env, EESSI_USER_INSTALL=str(mine)), cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(replay.returncode, 0, replay.stderr)
        self.assertEqual(replay.stdout, real.stdout)
        self.assertEqual(real.stdout.splitlines(), ["0077", "my recipe.eb", "--robot",
                                                    "EASYBUILD_PREFIX=/tmp/alice/easybuild",
                                                    f"EESSI_USER_INSTALL={mine}"])

    def test_every_argument_after_the_separator_is_ebs(self):
        # Before the separator, --help is eb-local's, as for every command.
        self.assertIn("eb-local eb [--] [eb options]", self.run_tool(["eb", "--help"]).stdout)
        self.assertFalse((self.root / "eb-ran").exists())
        explained = self.run_tool(["--explain", "eb", "--", "--help"])
        self.assertEqual(explained.returncode, 0, explained.stderr)
        self.assertIn("\nset -- 077 user --help\n", explained.stdout)
        args = ["--help", "-h", "--config", "x", "--profile", "y", "--project", "z", "--explain"]
        run = self.run_tool(["eb", "--"] + args)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.splitlines()[1:len(args) + 1], args)

    def test_explain_eb_refuses_two_install_variables_as_eb_does(self):
        run = self.run_tool(["--explain", "eb", "x.eb"], EESSI_USER_INSTALL="/x", EESSI_PROJECT_INSTALL="/y")
        self.assertEqual(run.returncode, 3, run.stdout)
        self.assertEqual(run.stdout, "")
        self.assertIn("EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL", run.stderr)

    def test_at_most_one_install_variable_and_none_is_the_modules_default(self):
        help_text = self.run_tool(["--help"]).stdout
        self.assertIn("At most one of EESSI_USER_INSTALL", help_text)
        self.assertNotIn("Exactly one", help_text)
        none = self.run_tool(["eb", "x.eb"])
        self.assertEqual(none.returncode, 0, none.stderr)
        self.assertIn("EESSI_USER_INSTALL=unset", none.stdout)
        two = self.run_tool(["eb", "x.eb"], EESSI_USER_INSTALL="/x", EESSI_SITE_INSTALL="")
        self.assertEqual(two.returncode, 3, two.stdout)
        self.assertIn("set at most one of EESSI_USER_INSTALL", two.stderr)
        self.assertIn("with none set, the module installs under $HOME/eessi", two.stderr)

    def test_a_leftover_user_install_beside_a_project_install_is_named(self):
        run = self.run_tool(["eb", "x.eb"], EESSI_USER_INSTALL="/home/alice/eessi", EESSI_PROJECT_INSTALL="/projects/a")
        self.assertEqual(run.returncode, 3, run.stdout)
        self.assertFalse((self.root / "eb-ran").exists())
        self.assertIn("eb-local: EESSI_USER_INSTALL=/home/alice/eessi and EESSI_PROJECT_INSTALL=/projects/a are both set; "
                      "EESSI-extend would make a private user install (umask 077) under /home/alice/eessi, "
                      "not a project install under /projects/a.\n"
                      "  Unset the one an earlier session left", run.stderr)

    def test_eb_stops_when_the_install_path_is_outside_the_selected_tree(self):
        mine = self.root / "mine"
        run = self.run_tool(["eb", "x.eb"], EESSI_USER_INSTALL=str(mine), CONTROL_INSTALLPATH="/elsewhere/hooktree")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse((self.root / "eb-ran").exists())
        self.assertIn(f"eb-local: EESSI-extend set the install path to /elsewhere/hooktree, outside {mine}, "
                      "where a user install goes; nothing was built.\n"
                      "  The install variable did not choose it: a site Lmod hook,", run.stderr)

    def test_eb_stops_on_a_leftover_install_path_for_modules(self):
        run = self.run_tool(["eb", "x.eb"], EASYBUILD_INSTALLPATH_MODULES="/home/alice/old-modules")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse((self.root / "eb-ran").exists())
        self.assertIn("eb-local: EASYBUILD_INSTALLPATH_MODULES=/home/alice/old-modules is set in this shell and would put "
                      f"part of this install outside {self.root / 'home' / 'eessi'}; nothing was built.\n  Unset it:",
                      run.stderr)

    def test_site_and_cvmfs_installs_go_into_the_trees_eessi_sets(self):
        for name in ("EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL"):
            with self.subTest(name=name):
                run = self.run_tool(["eb", "x.eb"], **{name: "1"})
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout.splitlines()[0], "0022")

    def test_explain_with_a_command_it_does_not_explain_is_refused(self):
        prefix = self.root / "prefix"
        logs = prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True)
        old = logs / "easybuild-old.log"
        old.write_text("log\n")
        os.utime(old, (time.time() - 90 * 86400,) * 2)
        for args in (["clean", "--delete"], ["submit", "x.eb"], ["uninstall", "GSL/2.8"], ["doctor"], ["env"]):
            with self.subTest(args=args):
                run = self.run_tool(["--explain"] + args, EB_LOCAL_PREFIX=str(prefix))
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertEqual(run.stdout, "")
                self.assertIn(f"--explain goes with a recipe or with eb, not with {args[0]}", run.stderr)
        self.assertTrue(old.exists())

    def test_eb_accepts_trailing_slash_in_install_variable(self):
        mine = self.root / "mine"
        run = self.run_tool(
            ["eb", "x.eb"],
            EESSI_USER_INSTALL=f"{mine}/",
            CONTROL_INSTALLPATH=f"{mine}/versions/2026.06/software/linux/x86_64/amd/zen4",
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue((self.root / "eb-ran").exists())


    def test_eb_refuses_directory_at_init_with_exit_two(self):
        init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init.unlink()
        init.mkdir()
        run = self.run_tool(["eb", "x.eb"])
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn(f"eb-local: cannot read {init}, the EESSI init; eb was not run.", run.stderr)
        self.assertFalse((self.root / "eb-ran").exists())

if __name__ == "__main__":
    unittest.main()
