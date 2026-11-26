#!/usr/bin/env python3
"""A build that is signalled stops, and its logs are cleaned after EasyBuild exits.

The eb double stands in for EasyBuild: a program, as the real eb is a script
that execs python, which records each signal it gets, and on the first takes
a moment before it writes its last log line, with the secret in it, and
exits as EasyBuild does (15 for SIGTERM, 1 for SIGINT). eb-local must wait
for it, clean the log, and then die of the signal.
"""
import os
from pathlib import Path
import pty
import shutil
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture

SLOW_EB = r'''
import os, signal, sys, time
root = os.environ["CONTROL_ROOT"]
got = []
def note(sig, frame):
    got.append(signal.Signals(sig).name)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    if signal.getsignal(sig) != signal.SIG_IGN:
        signal.signal(sig, note)
log = os.path.join(os.environ["EASYBUILD_TMP_LOGDIR"], "easybuild-slow.log")
with open(log, "w") as f:
    f.write("building\n")
open(os.path.join(root, "eb.pid"), "w").write(str(os.getpid()))
ready = os.environ.get("EB_READY")
done = os.environ.get("EB_DONE")
if ready and done:
    open(ready, "w").write("r")
    limit = time.monotonic() + 10
    while not os.path.exists(done) and time.monotonic() < limit:
        time.sleep(0.01)
    open(done + ".seen", "w").write("d")
    if not got:
        sys.exit(0)
deadline = time.monotonic() + float(os.environ.get("SLOW_EB_WAIT", "10"))
while not got and time.monotonic() < deadline:
    time.sleep(0.05)
if not got:
    sys.exit(0)
gate = os.environ.get("EB_SIGNAL_GATE")
if gate:
    with open(gate, "rb") as gate_file:
        gate_file.read(1)
else:
    time.sleep(0.5)
with open(log, "a") as f:
    f.write("stopping with " + os.environ["LICENCE_KEY"] + "\n")
open(os.path.join(root, "eb.signals"), "w").write(" ".join(got))
sys.exit(15 if got[0] == "SIGTERM" else 1)
'''

LATE_EB = r'''
import gzip, os
log = os.path.join(os.environ["EASYBUILD_TMP_LOGDIR"], "easybuild-late.log.gz")
with gzip.open(log, "wt") as f:
    f.write("built with " + os.environ["LICENCE_KEY"] + "\n")
'''

KEY = "licence-key-6f1c2e9a"


@unittest.skipUnless(binary.ZIG, "passing signals on is a feature of the Zig build")
class Signals(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)
        (self.root / "slow-eb.py").write_text(SLOW_EB)
        programs = self.root / "slow-bin"
        programs.mkdir()
        (programs / "eb").write_text('#!/bin/bash\nexec python3 "$CONTROL_ROOT/slow-eb.py" "$@"\n')
        (programs / "eb").chmod(0o755)
        slow = self.root / "doubles-slow.sh"
        slow.write_text((self.root / "doubles.sh").read_text() + "\nunset -f eb\n")
        argv, env = binary.command(self.script, ["recipe.eb"], dict(
            self.env, BASH_ENV=str(slow), LICENCE_SRC=KEY, EB_LOCAL_SECRET_LICENCE_KEY="env:LICENCE_SRC"))
        env["PATH"] = f"{programs}:{env['PATH']}"
        self.argv, self.build_env = argv, env
        self.log = self.prefix / ".eb-local" / "logs" / "easybuild-slow.log"

    def eb_pid(self):
        pid_file = self.root / "eb.pid"
        deadline = time.monotonic() + 20
        while not pid_file.exists():
            self.assertLess(time.monotonic(), deadline, "eb did not start")
            time.sleep(0.05)
        return int(pid_file.read_text())

    def assert_stopped_and_clean(self, eb):
        with self.assertRaises(ProcessLookupError):
            os.kill(eb, 0)
        text = self.log.read_text()
        self.assertIn("stopping with <secret LICENCE_KEY removed by eb-local>", text)
        self.assertNotIn(KEY, text)

    def open_gate(self, fifo):
        deadline = time.monotonic() + 5
        fd = None
        while fd is None:
            try:
                fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                self.assertLess(time.monotonic(), deadline, "eb did not reach the signal gate")
                time.sleep(0.01)
        os.write(fd, b"x")
        os.close(fd)

    def signalled(self, send, *, gate=False, **popen):
        if gate:
            fifo = self.root / "signal-gate"
            if fifo.exists():
                fifo.unlink()
            os.mkfifo(fifo)
            self.build_env["EB_SIGNAL_GATE"] = str(fifo)
        build = subprocess.Popen(self.argv, env=self.build_env, cwd=self.root, start_new_session=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **popen)
        self.addCleanup(lambda: build.poll() is None and os.killpg(build.pid, signal.SIGKILL))
        eb = self.eb_pid()
        sent = time.monotonic()
        send(build.pid)
        if gate:
            self.open_gate(fifo)
        out, err = build.communicate(timeout=30)
        self.assertLess(time.monotonic() - sent, 8, out + err)
        return build.returncode, out, err, eb

    def test_a_sigterm_to_eb_local_alone_reaches_easybuild(self):
        rc, out, err, eb = self.signalled(lambda pid: os.kill(pid, signal.SIGTERM), gate=True)
        self.assertEqual(rc, -signal.SIGTERM, out + err)
        self.assertEqual((self.root / "eb.signals").read_text(), "SIGTERM")
        self.assert_stopped_and_clean(eb)
        self.assertIn("removed secret values from 1 log file(s)", out)
        self.assertIn("build workspace kept", err)

    def test_a_sigterm_to_the_process_group_waits_for_easybuild_before_the_logs_are_cleaned(self):
        rc, out, err, eb = self.signalled(lambda pid: os.killpg(pid, signal.SIGTERM), gate=True)
        self.assertEqual(rc, -signal.SIGTERM, out + err)
        self.assertTrue((self.root / "eb.signals").read_text().startswith("SIGTERM"))
        self.assert_stopped_and_clean(eb)

    def test_a_signal_ignored_as_nohup_ignores_sighup_stays_ignored(self):
        ready = self.root / "eb.ready"
        done = self.root / "eb.done"
        self.build_env["EB_READY"] = str(ready)
        self.build_env["EB_DONE"] = str(done)
        build = subprocess.Popen(self.argv, env=self.build_env, cwd=self.root, start_new_session=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 preexec_fn=lambda: signal.signal(signal.SIGHUP, signal.SIG_IGN))
        self.addCleanup(lambda: build.poll() is None and os.killpg(build.pid, signal.SIGKILL))
        self.eb_pid()
        deadline = time.monotonic() + 5
        while not ready.exists():
            self.assertLess(time.monotonic(), deadline, "eb did not become ready")
            time.sleep(0.01)
        os.killpg(build.pid, signal.SIGHUP)
        done.write_text("d")
        seen = Path(str(done) + ".seen")
        while not seen.exists():
            self.assertLess(time.monotonic(), deadline + 5, "done byte did not arrive")
            time.sleep(0.01)
        out, err = build.communicate(timeout=30)
        self.assertEqual(build.returncode, 0, out + err)
        self.assertFalse((self.root / "eb.signals").exists())

    def test_ctrl_c_on_the_terminal_reaches_easybuild_once(self):
        fifo = self.root / "signal-gate"
        os.mkfifo(fifo)
        self.build_env["EB_SIGNAL_GATE"] = str(fifo)
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execve(self.argv[0], self.argv, self.build_env)
        self.addCleanup(os.close, master)
        output = b""
        eb = self.eb_pid()
        os.write(master, b"\x03")
        self.open_gate(fifo)
        deadline = time.monotonic() + 30
        while True:
            self.assertLess(time.monotonic(), deadline, output)
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
        _, status = os.waitpid(pid, 0)
        self.assertTrue(os.WIFSIGNALED(status), output)
        self.assertEqual(os.WTERMSIG(status), signal.SIGINT)
        # The terminal sent it to the whole foreground group; eb-local passes
        # on only what was sent to it alone.
        self.assertEqual((self.root / "eb.signals").read_text(), "SIGINT")
        self.assert_stopped_and_clean(eb)

    def test_a_sigterm_while_the_logs_are_cleaned_drops_a_failed_lock_release(self):
        # EasyBuild has exited; the gzip that cleaning its log runs sends the
        # signal, before the workspace and its lock go.
        late = self.root / "late-bin"
        late.mkdir()
        (self.root / "late-eb.py").write_text(LATE_EB)
        (late / "eb").write_text('#!/bin/bash\nexec python3 "$CONTROL_ROOT/late-eb.py" "$@"\n')
        (late / "gzip").write_text(f'#!/bin/bash\nkill -TERM "$PPID"\nexec {shutil.which("gzip")} "$@"\n')
        for program in late.iterdir():
            program.chmod(0o755)
        env = dict(self.build_env, PATH=f"{late}:{self.build_env['PATH']}", EB_LOCAL_TEST_RELEASE_ERRNO="EIO")
        run = subprocess.run(self.argv, env=env, cwd=self.root, start_new_session=True,
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, -signal.SIGTERM, run.stdout + run.stderr)
        self.assertNotIn("cannot release", run.stderr)


if __name__ == "__main__":
    unittest.main()
