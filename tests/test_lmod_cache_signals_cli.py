#!/usr/bin/env python3
"""Signal forwarding and temporary directory cleanup in `eb-local lmod-cache`."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

import binary

HELPER = r'''
import os, select, signal, sys

tag = sys.argv[1]
root = sys.argv[2]
ignore = len(sys.argv) > 3 and sys.argv[3] == "ignore"
got = []
rfd, wfd = os.pipe()
os.set_blocking(wfd, False)
signal.set_wakeup_fd(wfd, warn_on_full_buffer=False)

def write_atomic(name, text):
    tmp = os.path.join(root, f".{name}.{os.getpid()}.tmp")
    dst = os.path.join(root, name)
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, dst)

def note(sig, _frame):
    got.append(signal.Signals(sig).name)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    if ignore:
        signal.signal(sig, signal.SIG_IGN)
    elif signal.getsignal(sig) != signal.SIG_IGN:
        signal.signal(sig, note)

write_atomic(f"{tag}.pid", str(os.getpid()))
while not got:
    ready, _, _ = select.select([rfd], [], [], 20.0)
    if not ready:
        break
    try:
        os.read(rfd, 64)
    except OSError:
        pass

if got:
    write_atomic(f"{tag}.signals", " ".join(got))
sys.exit(0)
'''

SLOW_SPIDER = r'''#!/usr/bin/env python3
import os, select, signal, subprocess, sys, time

root = os.environ["CONTROL_ROOT"]
helper = os.path.join(root, "helper.py")
got = []
rfd, wfd = os.pipe()
os.set_blocking(wfd, False)
signal.set_wakeup_fd(wfd, warn_on_full_buffer=False)

def write_atomic(name, text):
    tmp = os.path.join(root, f".{name}.{os.getpid()}.tmp")
    dst = os.path.join(root, name)
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, dst)

def note(sig, _frame):
    got.append(signal.Signals(sig).name)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    if signal.getsignal(sig) != signal.SIG_IGN:
        signal.signal(sig, note)

w = subprocess.Popen(
    [sys.executable, helper, "worker", root],
    close_fds=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
s = subprocess.Popen(
    [sys.executable, helper, "straggler", root, "ignore"],
    close_fds=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
for name in ("worker.pid", "straggler.pid"):
    target = os.path.join(root, name)
    deadline = time.monotonic() + 10.0
    while not os.path.exists(target):
        if time.monotonic() >= deadline:
            sys.exit(99)
        time.sleep(0.005)

write_atomic("spider.pid", str(os.getpid()))
while not got:
    ready, _, _ = select.select([rfd], [], [], 20.0)
    if not ready:
        break
    try:
        os.read(rfd, 64)
    except OSError:
        pass

if got:
    write_atomic("spider.signals", " ".join(got))
    sys.exit(1)
w.terminate()
s.kill()
sys.exit(0)
'''


def stop_proc(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    if proc.stdout:
        proc.stdout.close()
    if proc.stderr:
        proc.stderr.close()


def kill_quiet(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def pid_gone(pid, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.005)
    return False


@unittest.skipUnless(binary.ZIG, "lmod-cache is a feature of the Zig build")
class LmodCacheSignalGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-lmod-sig-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "helper.py").write_text(HELPER, encoding="utf-8")
        self.slow_spider = self.root / "slow-spider"
        self.slow_spider.write_text(SLOW_SPIDER, encoding="utf-8")
        self.slow_spider.chmod(0o755)
        self.modules = self.root / "modules"
        self.modules.mkdir()

    def reset_markers(self):
        for name in ("spider.pid", "spider.signals", "worker.pid", "worker.signals", "straggler.pid"):
            (self.root / name).unlink(missing_ok=True)

    def wait_pid(self, name):
        path = self.root / name
        deadline = time.monotonic() + 15.0
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"{name} did not appear")
            time.sleep(0.005)
        pid = int(path.read_text(encoding="utf-8").strip())
        self.addCleanup(lambda: kill_quiet(pid))
        return pid

    def test_signals_during_spider_verify_and_prefix_forward_to_pgroup_and_clean_temps(self):
        cache = self.root / "cache"
        stamp = self.root / "system.txt"
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "CONTROL_ROOT": str(self.root)}

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(mode="spider", signal=sig.name):
                self.reset_markers()
                proc = subprocess.Popen(
                    [
                        binary.ZIG,
                        "lmod-cache",
                        "--modulepath",
                        str(self.modules),
                        "--cache-dir",
                        str(cache),
                        "--timestamp",
                        str(stamp),
                        "--spider",
                        str(self.slow_spider),
                    ],
                    env=env,
                    cwd=self.root,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(lambda p=proc: stop_proc(p))
                spider_pid = self.wait_pid("spider.pid")
                worker_pid = self.wait_pid("worker.pid")
                straggler_pid = self.wait_pid("straggler.pid")

                os.kill(proc.pid, sig)
                out, err = proc.communicate(timeout=10)
                self.assertEqual(proc.returncode, -sig, out + err)
                self.assertEqual(out, "")
                self.assertTrue((self.root / "worker.signals").exists(), "spider worker missed signal")
                self.assertEqual((self.root / "worker.signals").read_text(encoding="utf-8"), sig.name)
                self.assertTrue(pid_gone(spider_pid, 1.0))
                self.assertTrue(pid_gone(worker_pid, 1.0))
                self.assertTrue(pid_gone(straggler_pid, 1.0))
                self.assertFalse(cache.exists())
                self.assertFalse(stamp.exists())

        fast_spider = self.root / "fast-spider"
        fast_spider.write_text("#!/bin/sh\nprintf 'spider-cache\\n'\n", encoding="utf-8")
        fast_spider.chmod(0o755)
        bin_dir = self.root / "verify-bin"
        bin_dir.mkdir()
        slow_module = bin_dir / "module"
        slow_module.write_text(
            '#!/bin/sh\nexec "' + str(self.slow_spider) + '"\n',
            encoding="utf-8",
        )
        slow_module.chmod(0o755)
        verify_cache = self.root / "verify-cache"
        verify_cache.mkdir()
        (verify_cache / "spiderT.lua").write_text("keep-cache\n", encoding="utf-8")
        verify_stamp = self.root / "verify-stamp"
        verify_stamp.write_text("keep-stamp\n", encoding="utf-8")

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(mode="verify", signal=sig.name):
                self.reset_markers()
                proc = subprocess.Popen(
                    [
                        binary.ZIG,
                        "lmod-cache",
                        "--modulepath",
                        str(self.modules),
                        "--cache-dir",
                        str(verify_cache),
                        "--timestamp",
                        str(verify_stamp),
                        "--spider",
                        str(fast_spider),
                        "--verify",
                    ],
                    env={**env, "PATH": f"{bin_dir}:/usr/bin:/bin"},
                    cwd=self.root,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(lambda p=proc: stop_proc(p))
                worker_pid = self.wait_pid("worker.pid")
                straggler_pid = self.wait_pid("straggler.pid")
                self.assertTrue(any(p.name.startswith(".eb-local-verify-") for p in verify_cache.iterdir()))

                os.kill(proc.pid, sig)
                out, err = proc.communicate(timeout=10)
                self.assertEqual(proc.returncode, -sig, out + err)
                self.assertEqual(out, "")
                self.assertTrue((self.root / "worker.signals").exists(), "verify worker missed signal")
                self.assertEqual((self.root / "worker.signals").read_text(encoding="utf-8"), sig.name)
                self.assertTrue(pid_gone(worker_pid, 1.0))
                self.assertTrue(pid_gone(straggler_pid, 1.0))
                self.assertEqual(sorted(p.name for p in verify_cache.iterdir()), ["spiderT.lua"])
                self.assertEqual((verify_cache / "spiderT.lua").read_text(encoding="utf-8"), "keep-cache\n")
                self.assertEqual(verify_stamp.read_text(encoding="utf-8"), "keep-stamp\n")

        prefix = self.root / "prefix"
        cpu = prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (cpu / "modules" / "all").mkdir(parents=True)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(mode="prefix", signal=sig.name):
                self.reset_markers()
                proc = subprocess.Popen(
                    [
                        binary.ZIG,
                        "lmod-cache",
                        "--prefix",
                        str(prefix),
                        "--update-cmd",
                        str(self.slow_spider),
                    ],
                    env=env,
                    cwd=self.root,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(lambda p=proc: stop_proc(p))
                worker_pid = self.wait_pid("worker.pid")
                straggler_pid = self.wait_pid("straggler.pid")

                os.kill(proc.pid, sig)
                out, err = proc.communicate(timeout=10)
                self.assertEqual(proc.returncode, -sig, out + err)
                self.assertTrue((self.root / "worker.signals").exists(), "prefix updater worker missed signal")
                self.assertEqual((self.root / "worker.signals").read_text(encoding="utf-8"), sig.name)
                self.assertTrue(pid_gone(worker_pid, 1.0))
                self.assertTrue(pid_gone(straggler_pid, 1.0))


if __name__ == "__main__":
    unittest.main()
