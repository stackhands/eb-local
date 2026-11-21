#!/usr/bin/env python3
"""A command that lists what it will change writes the list first.

When standard output cannot take the list, the command stops with a
diagnostic on standard error and exit status 1, and changes nothing: no
file, no directory, not even the prefix lock. When a later write fails,
nothing is left half done. The Zig program and the POSIX shell shim that
delegate to it agree on the status, the message and the files left behind.
"""

import fcntl
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary
from stdout_scene import BROKEN_SINKS, Scene, make_front_ends, run_with_stdout, snapshot


@unittest.skipUnless(binary.ZIG and os.path.exists("/dev/full"), "needs the Zig build and /dev/full")
class PlanBeforeChange(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix=f"eb-local-plan-{os.getpid()}-")
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.front_ends = make_front_ends(self.tmp)
        self.count = 0

    def scene(self, **kwargs):
        self.count += 1
        return Scene(self.tmp / f"scene-{self.count}", **kwargs)

    def run_scene(self, scene, front_end, sink, args):
        argv = [*self.front_ends[front_end], *args]
        done = run_with_stdout(argv, sink, env=scene.env, cwd=scene.root)
        return done.returncode, done.stderr.decode("utf-8"), snapshot(scene.root)

    def check_unchanged(self, name, make, args, *, changed, nothing, sinks=BROKEN_SINKS, control_code=0):
        """Both front ends stop alike on every broken sink and leave the tree as it was.

        MAKE builds a scene; CHANGED(scene) says whether the command did its
        work, and a working stdout must show that it does. The tree includes
        the prefix lock, which the command makes only once it has its plan out.
        """
        for front_end in self.front_ends:
            with self.subTest(command=name, front_end=front_end, sink="ok"):
                scene = make(self)
                code, err, _ = self.run_scene(scene, front_end, "ok", args)
                if control_code is not None:
                    self.assertEqual(code, control_code, err)
                self.assertTrue(changed(scene), "the control run must do the work")
        for sink, errno_text in sinks.items():
            seen = {}
            for front_end in self.front_ends:
                with self.subTest(command=name, front_end=front_end, sink=sink):
                    scene = make(self)
                    before = snapshot(scene.root)
                    self.assertFalse((scene.prefix / ".eb-local" / ".lock").exists())
                    code, err, after = self.run_scene(scene, front_end, sink, args)
                    err = err.replace(str(scene.root), "<root>")
                    self.assertFalse(changed(scene), "the command changed state")
                    self.assertEqual(scene.calls(), [], "no double may run")
                    self.assertEqual(after, before)
                    self.assertEqual(code, 1, err)
                    self.assertIn("cannot write output ([Errno", err)
                    self.assertIn(errno_text, err)
                    self.assertIn(f"nothing was {nothing}", err)
                    seen[front_end] = (code, err, sorted(after))
            with self.subTest(command=name, sink=sink, parity="zig and shell"):
                if len(seen) == len(self.front_ends):
                    self.assertEqual(seen["zig"], seen["shell"])

    def check_every_write(self, name, make, args, *, listed, nothing):
        """Fail standard output after each number of writes; the tree is never half done.

        A run with a working stdout shows what the command does and how many
        writes it makes. LISTED of them are the plan. Failing any of those
        leaves the tree and the doubles as they were. Failing a later one leaves
        the command done, because the plan was out before it began, and still
        exits 1.
        """
        for front_end in self.front_ends:
            control = make(self)
            before = snapshot(control.root)
            argv = [*self.front_ends[front_end], *args]
            done = subprocess.run(
                argv, env=control.env, cwd=control.root, stdin=subprocess.DEVNULL, capture_output=True, timeout=60
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            finished = snapshot(control.root)
            finished_calls = [call.replace(str(control.root), "<root>") for call in control.calls()]
            self.assertNotEqual(finished, before, "the control run must do the work")
            writes = len(done.stdout.decode().splitlines())
            self.assertGreater(writes, listed)
            for n in range(writes + 1):
                with self.subTest(command=name, front_end=front_end, writes_that_succeed=n):
                    scene = make(self)
                    before = snapshot(scene.root)
                    env = dict(scene.env, EB_LOCAL_TEST_STDOUT_WRITES=str(n))
                    run = subprocess.run(
                        argv, env=env, cwd=scene.root, stdin=subprocess.DEVNULL, capture_output=True, timeout=60
                    )
                    err = run.stderr.decode().replace(str(scene.root), "<root>")
                    calls = [call.replace(str(scene.root), "<root>") for call in scene.calls()]
                    if n < listed:
                        self.assertEqual(snapshot(scene.root), before, "the plan did not get out")
                        self.assertEqual(calls, [])
                        self.assertIn(f"nothing was {nothing}", err)
                    else:
                        self.assertEqual(snapshot(scene.root), finished)
                        self.assertEqual(calls, finished_calls)
                        self.assertNotIn(f"nothing was {nothing}", err)
                    self.assertEqual(run.returncode, 1 if n < writes else 0, err)
                    if n < writes:
                        self.assertIn("cannot write output ([Errno 28]", err)

    def check_changed_under_the_lock(self, name, make, args, *, listed, change, kept, code, message):
        """A change between the list and the lock stops the command with nothing removed.

        The test holds the prefix lock, so the command writes its list and waits.
        Once the LISTED lines are read, CHANGE(scene) alters what was listed and
        the lock is released. KEPT(scene) is what must still be there.
        """
        for front_end in self.front_ends:
            with self.subTest(command=name, front_end=front_end):
                scene = make(self)
                lock_dir = scene.prefix / ".eb-local"
                lock_dir.mkdir(exist_ok=True)
                with open(lock_dir / ".lock", "a+") as held:
                    fcntl.flock(held, fcntl.LOCK_EX)
                    run = subprocess.Popen(
                        [*self.front_ends[front_end], *args],
                        env={**scene.env, "EB_LOCAL_LOCK_TIMEOUT_MS": "5000"},
                        cwd=scene.root,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    self.addCleanup(run.kill)
                    for _ in range(listed):
                        run.stdout.readline()
                    change(scene)
                    fcntl.flock(held, fcntl.LOCK_UN)
                _, err = run.communicate(timeout=60)
                err = err.decode()
                self.assertEqual(run.returncode, code, err)
                self.assertIn(message, err)
                self.assertTrue(kept(scene), "nothing may be removed")
                self.assertEqual(scene.calls(), [])

    def test_clean_lists_before_it_removes_anything(self):
        def deleting(test):
            scene = test.scene()
            scene.old_log()
            return scene

        def trashing(test):
            scene = test.scene()
            scene.old_log()
            scene.rtrash_recorder()
            return scene

        def log_gone(scene):
            return not (scene.prefix / ".eb-local" / "logs" / "easybuild-old.log").exists()

        self.check_unchanged("clean --delete", deleting, ["clean", "--delete"], changed=log_gone, nothing="removed")
        self.check_unchanged(
            "clean (rtrash)", trashing, ["clean"], changed=lambda s: s.marker.exists(), nothing="removed"
        )

    def test_clean_forgets_a_stale_workspace_root_only_once_it_has_said_there_is_nothing_to_clean(self):
        def stale_root(test):
            scene = test.scene()
            scene.stale_record = scene.stale_workspace_root()
            return scene

        self.check_unchanged(
            "clean --workspaces",
            stale_root,
            ["clean", "--workspaces"],
            changed=lambda scene: not scene.stale_record.exists(),
            nothing="removed",
        )

    def test_clean_checks_its_list_again_once_it_has_the_lock(self):
        def two_old_logs(test):
            scene = test.scene()
            scene.old_log()
            second = scene.prefix / ".eb-local" / "logs" / "easybuild-older.log"
            second.write_text("log\n", encoding="utf-8")
            os.utime(second, (1_000_000_001, 1_000_000_001))
            return scene

        logs = lambda scene: scene.prefix / ".eb-local" / "logs"
        self.check_changed_under_the_lock(
            "clean --delete",
            two_old_logs,
            ["clean", "--delete"],
            listed=2,
            change=lambda scene: (logs(scene) / "easybuild-old.log").unlink(),
            kept=lambda scene: (logs(scene) / "easybuild-older.log").exists(),
            code=1,
            message="changed while it waited for the prefix lock; nothing was removed",
        )

    def test_clean_reports_after_it_has_changed_everything(self):
        def logs_and_a_workspace(test):
            scene = test.scene()
            job = scene.in_a_job()
            scene.old_log()
            (scene.prefix / ".eb-local" / "logs" / "easybuild-older.log").write_text("log\n", encoding="utf-8")
            os.utime(scene.prefix / ".eb-local" / "logs" / "easybuild-older.log", (1_000_000_001, 1_000_000_001))
            (job / "eb-local.AbCdEf12").mkdir()
            return scene

        def trashing(test):
            scene = logs_and_a_workspace(test)
            scene.rtrash_recorder()
            return scene

        self.check_every_write(
            "clean --workspaces --delete",
            logs_and_a_workspace,
            ["clean", "--workspaces", "--delete"],
            listed=3,
            nothing="removed",
        )
        self.check_every_write(
            "clean --workspaces (rtrash)", trashing, ["clean", "--workspaces"], listed=3, nothing="removed"
        )

    def test_uninstall_lists_before_it_removes_anything(self):
        def deleting(test):
            scene = test.scene()
            scene.demo_install()
            return scene

        def trashing(test):
            scene = deleting(test)
            scene.rtrash_recorder()
            return scene

        def install_gone(scene):
            return not any((scene.prefix / "versions").rglob("Demo"))

        self.check_unchanged(
            "uninstall --delete", deleting, ["uninstall", "--delete", "Demo/1.0"], changed=install_gone, nothing="removed"
        )
        self.check_unchanged(
            "uninstall (rtrash)", trashing, ["uninstall", "Demo/1.0"], changed=lambda s: s.marker.exists(), nothing="removed"
        )

    def test_uninstall_checks_its_list_again_once_it_has_the_lock(self):
        def installed(test):
            scene = test.scene()
            scene.demo_install()
            return scene

        def module_file(scene):
            return next((scene.prefix / "versions").rglob("1.0.lua"))

        self.check_changed_under_the_lock(
            "uninstall --delete",
            installed,
            ["uninstall", "--delete", "Demo/1.0"],
            listed=2,
            change=lambda scene: module_file(scene).unlink(),
            kept=lambda scene: any((scene.prefix / "versions").rglob("Demo")),
            code=1,
            message="changed while it waited for the prefix lock; nothing was removed",
        )

    def test_uninstall_refuses_what_was_added_while_it_waited_for_the_lock(self):
        def installed(test):
            scene = test.scene()
            scene.demo_install()
            return scene

        def class_link(scene):
            return next((scene.prefix / "versions").rglob("modules")) / "tools" / "Demo" / "1.0.lua"

        def link_the_module(scene):
            link = class_link(scene)
            link.parent.mkdir(parents=True)
            link.symlink_to(next((scene.prefix / "versions").rglob("1.0.lua")))

        self.check_changed_under_the_lock(
            "uninstall --delete",
            installed,
            ["uninstall", "--delete", "Demo/1.0"],
            listed=2,
            change=link_the_module,
            kept=lambda scene: any((scene.prefix / "versions").rglob("Demo")) and class_link(scene).is_symlink(),
            code=1,
            message="changed while it waited for the prefix lock; nothing was removed",
        )

    def test_uninstall_reports_after_it_has_changed_everything(self):
        def deleting(test):
            scene = test.scene()
            scene.demo_install()
            return scene

        def trashing(test):
            scene = deleting(test)
            scene.rtrash_recorder()
            return scene

        self.check_every_write(
            "uninstall --delete", deleting, ["uninstall", "--delete", "Demo/1.0"], listed=2, nothing="removed"
        )
        self.check_every_write("uninstall (rtrash)", trashing, ["uninstall", "Demo/1.0"], listed=2, nothing="removed")

    def test_restore_lists_before_it_restores_anything(self):
        def trashed(test):
            scene = test.scene()
            scene.trashed_install()
            return scene

        self.check_unchanged(
            "restore", trashed, ["restore", "Restored/1.0"], changed=lambda s: s.marker.exists(), nothing="restored"
        )

    def test_restore_reads_the_trash_again_once_it_has_the_lock(self):
        for front_end in self.front_ends:
            with self.subTest(front_end=front_end):
                scene = self.scene()
                scene.trashed_install(lists_once=True)
                code, err, _ = self.run_scene(scene, front_end, "ok", ["restore", "Restored/1.0"])
                self.assertEqual(code, 2, err)
                self.assertIn("is not in the trash", err)
                self.assertEqual(scene.calls(), [], "nothing may be restored")

    def test_restore_reports_after_it_has_changed_everything(self):
        def trashed(test):
            scene = test.scene()
            scene.trashed_install()
            return scene

        self.check_every_write("restore", trashed, ["restore", "Restored/1.0"], listed=2, nothing="restored")


if __name__ == "__main__":
    unittest.main()
