#!/usr/bin/env python3
"""`SIGINT` during bash setup in `build_script` and `extend.script` stops before `exec eb`."""

import os
from pathlib import Path
import select
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture

SETUP_HELPER = r'''
import os, select, signal, sys, time

root = os.environ["CONTROL_ROOT"]
tag = os.environ["HELPER_TAG"]
code = int(os.environ.get("HELPER_EXIT", "0"))

def write_atomic(path, text):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)

sig_r, sig_w = os.pipe()
os.set_blocking(sig_w, False)
def on_sig(_sig, _frame):
    try:
        os.write(sig_w, b"1")
    except OSError:
        pass
signal.signal(signal.SIGINT, on_sig)
write_atomic(os.path.join(root, f"{tag}.pid"), str(os.getpid()))

poller = select.poll()
poller.register(sig_r, select.POLLIN)
deadline = time.monotonic() + 5.0
while True:
    rem_ms = int((deadline - time.monotonic()) * 1000)
    if rem_ms <= 0:
        break
    try:
        if poller.poll(rem_ms):
            break
    except InterruptedError:
        continue

sys.exit(code)
'''

GATE_EB = r'''
import os, select, signal, sys, time

root = os.environ["CONTROL_ROOT"]

def write_atomic(path, text):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)

sig_state = signal.getsignal(signal.SIGINT)
if sig_state is signal.default_int_handler:
    label = "SIG_DFL"
elif sig_state == signal.SIG_IGN:
    label = "SIG_IGN"
else:
    label = repr(sig_state)

gate_r = -1
if os.environ.get("EB_WAIT_GATE", "1") == "1":
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    gate_r = os.open(os.path.join(root, "eb.release"), os.O_RDONLY | os.O_NONBLOCK)

write_atomic(os.path.join(root, "eb.ran"), label)

if gate_r >= 0:
    poller = select.poll()
    poller.register(gate_r, select.POLLIN)
    deadline = time.monotonic() + 2.0
    while True:
        rem_ms = int((deadline - time.monotonic()) * 1000)
        if rem_ms <= 0:
            break
        try:
            if poller.poll(rem_ms):
                break
        except InterruptedError:
            continue
    os.close(gate_r)

sys.exit(0)
'''


def wait_file(path: Path, timeout: float = 10.0) -> str:
    poller = select.poll()
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {path}")
        poller.poll(2)
    return path.read_text(encoding="utf-8")


@unittest.skipUnless(binary.ZIG, "bash setup SIGINT handling belongs to the Zig binary")
class BashSetupSigintCli(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)
        (self.root / "setup-helper.py").write_text(SETUP_HELPER, encoding="utf-8")
        (self.root / "gate-eb.py").write_text(GATE_EB, encoding="utf-8")

        self.bins = self.root / "setup-bin"
        self.bins.mkdir()
        probe = self.bins / "lmod-setup-probe"
        probe.write_text(
            '#!/bin/bash\nexport HELPER_TAG=probe\nexec python3 "$CONTROL_ROOT/setup-helper.py" "$@"\n',
            encoding="utf-8",
        )
        probe.chmod(0o755)
        eb = self.bins / "eb"
        eb.write_text('#!/bin/bash\nexec python3 "$CONTROL_ROOT/gate-eb.py" "$@"\n', encoding="utf-8")
        eb.chmod(0o755)
        rustc = self.bins / "rustc"
        rustc.write_text('#!/bin/sh\nprintf "host: x86_64-unknown-linux-gnu\\n"\n', encoding="utf-8")
        rustc.chmod(0o755)

        hooked = self.root / "doubles-hooked.sh"
        hooked.write_text(
            (self.root / "doubles.sh").read_text()
            + "\nunset -f eb\n"
            + 'orig_module=$(declare -f module)\n'
            + 'eval "orig_${orig_module}"\n'
            + 'module() {\n'
            + '  if [ "$1" = "load" ] && [ "${PROBE_MODULE_LOAD:-0}" = "1" ] && [ ! -e "$CONTROL_ROOT/probe.once" ]; then\n'
            + '    : > "$CONTROL_ROOT/probe.once"\n'
            + '    lmod-setup-probe || return $?\n'
            + '  fi\n'
            + '  orig_module "$@"\n'
            + '}\n',
            encoding="utf-8",
        )
        self.hooked = hooked

    @staticmethod
    def stop_popen(proc: subprocess.Popen):
        if proc.poll() is None:
            proc.kill()
        try:
            proc.communicate(timeout=2)
        except Exception:
            pass

    def reset_markers(self):
        for name in ("probe.pid", "probe.once", "eb.ran", "eb.release"):
            p = self.root / name
            if p.exists() or p.is_symlink():
                p.unlink()
        os.mkfifo(self.root / "eb.release")

    def await_abort_or_eb_gate(self, proc: subprocess.Popen, timeout: float = 3.0):
        poller = select.poll()
        eb_ran = self.root / "eb.ran"
        release = self.root / "eb.release"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            if eb_ran.exists():
                try:
                    wfd = os.open(release, os.O_WRONLY | os.O_NONBLOCK)
                    try:
                        os.write(wfd, b"1")
                    finally:
                        os.close(wfd)
                except OSError:
                    pass
                return
            poller.poll(2)

    def test_sigint_during_build_setup_stops_without_stalling_or_launching_eb(self):
        for exit_code in ("0", "130"):
            with self.subTest(helper_exit=exit_code):
                self.reset_markers()
                argv, env = binary.command(
                    self.script,
                    ["recipe.eb"],
                    dict(
                        self.env,
                        BASH_ENV=str(self.hooked),
                        PROBE_MODULE_LOAD="1",
                        HELPER_EXIT=exit_code,
                        EB_WAIT_GATE="1",
                    ),
                )
                env["PATH"] = f"{self.bins}:{env['PATH']}"

                proc = subprocess.Popen(
                    argv,
                    env=env,
                    cwd=self.root,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(self.stop_popen, proc)
                wait_file(self.root / "probe.pid")

                os.kill(proc.pid, signal.SIGINT)
                self.await_abort_or_eb_gate(proc)
                out, err = proc.communicate(timeout=5)

                self.assertEqual(proc.returncode, -signal.SIGINT, out + err)
                self.assertFalse((self.root / "eb.ran").exists(), out + err)
                self.assertNotIn("could not load EESSI", err)

    def test_sigint_during_extend_setup_stops_without_launching_eb(self):
        eessi_init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        eessi_init.parent.mkdir(parents=True, exist_ok=True)
        eessi_init.write_text(
            'module() {\n'
            '  lmod-setup-probe || return $?\n'
            '  export EASYBUILD_INSTALLPATH="${EESSI_USER_INSTALL:-$HOME/eessi}/versions/2026.06"\n'
            '}\n',
            encoding="utf-8",
        )

        for exit_code in ("0", "130"):
            with self.subTest(helper_exit=exit_code):
                self.reset_markers()
                argv, env = binary.command(
                    self.script,
                    ["eb", "zlib.eb"],
                    dict(
                        self.env,
                        SLURM_JOB_ID="",
                        EESSI_CVMFS_REPO=str(self.root / "repo"),
                        EESSI_USER_INSTALL=str(self.root / "user-eessi"),
                        HELPER_EXIT=exit_code,
                        EB_WAIT_GATE="1",
                    ),
                )
                env["PATH"] = f"{self.bins}:{env['PATH']}"

                proc = subprocess.Popen(
                    argv,
                    env=env,
                    cwd=self.root,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(self.stop_popen, proc)
                wait_file(self.root / "probe.pid")

                os.kill(proc.pid, signal.SIGINT)
                self.await_abort_or_eb_gate(proc)
                out, err = proc.communicate(timeout=5)

                self.assertEqual(proc.returncode, -signal.SIGINT, out + err)
                self.assertFalse((self.root / "eb.ran").exists(), out + err)

    def test_exec_eb_inherits_default_sigint_disposition_after_setup(self):
        self.reset_markers()
        argv, env = binary.command(
            self.script,
            ["recipe.eb"],
            dict(
                self.env,
                BASH_ENV=str(self.hooked),
                PROBE_MODULE_LOAD="0",
                EB_WAIT_GATE="0",
            ),
        )
        env["PATH"] = f"{self.bins}:{env['PATH']}"
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.root / "eb.ran").read_text(encoding="utf-8"), "SIG_DFL")


if __name__ == "__main__":
    unittest.main()
