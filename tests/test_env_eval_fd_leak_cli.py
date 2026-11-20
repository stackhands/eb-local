#!/usr/bin/env python3
"""No leaked pipe descriptors or leftover scratch dirs in `env`/`dev` evaluation."""

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest

import binary

FD_PROBE = r'''#!/usr/bin/env python3
import json, os, sys

tag = sys.argv[1]
out_file = os.environ["FD_RECORD_DIR"] + f"/{tag}.json"
names = os.listdir("/proc/self/fd")
open_fds = sorted(int(n) for n in names if os.path.lexists(f"/proc/self/fd/{n}"))
tmp = f"{out_file}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(open_fds, fh)
os.replace(tmp, out_file)
'''


@unittest.skipUnless(binary.BIN, "env/dev JSON and lock evaluation belong to the Zig binary")
class EnvEvalFdLeakCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-env-fd-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.tmp_scratch = self.root / "scratch-tmp"
        self.tmp_scratch.mkdir()
        self.records = self.root / "records"
        self.records.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.prefix = self.root / "prefix"
        self.prefix.mkdir()

        probe = self.root / "fd-probe.py"
        probe.write_text(FD_PROBE, encoding="utf-8")
        probe.chmod(0o755)

        self.bins = self.root / "bins"
        self.bins.mkdir()
        guard = self.bins / "eessi-arch-guard"
        guard.write_text(
            "#!/bin/sh\n"
            f"python3 '{probe}' guard\n"
            "printf 'export EESSI_SOFTWARE_SUBDIR=x86_64/generic\\n'\n",
            encoding="utf-8",
        )
        guard.chmod(0o755)

        eessi_init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        eessi_init.parent.mkdir(parents=True)
        eessi_init.write_text(
            "export EESSI_VERSION=2026.06\n"
            "export EESSI_SOFTWARE_SUBDIR=x86_64/generic\n"
            "module() {\n"
            f"  python3 '{probe}' module\n"
            "  if [ \"${FAIL_WITH_BG:-0}\" = \"1\" ]; then\n"
            "    python3 -c 'import os, time\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "    for fd in (0, 1, 2):\n"
            "        try: os.close(fd)\n"
            "        except OSError: pass\n"
            "    with open(os.environ[\"BG_PID_FILE\"], \"w\") as fh:\n"
            "        fh.write(str(os.getpid()))\n"
            "    time.sleep(10)\n"
            "    os._exit(0)\n"
            "' \n"
            "    exit 1\n"
            "  fi\n"
            "  if [ \"$1\" = \"load\" ]; then\n"
            "    shift\n"
            "    for m in \"$@\"; do\n"
            "      export LOADEDMODULES=\"${LOADEDMODULES:+$LOADEDMODULES:}$m\"\n"
            "    done\n"
            "  fi\n"
            "}\n",
            encoding="utf-8",
        )

    def base_env(self, **extra):
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("EB_LOCAL_") and not k.startswith("EESSI_")
        }
        env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.root / "xdg"),
            TMPDIR=str(self.tmp_scratch),
            SLURM_JOB_ID="",
            EB_LOCAL_PREFIX=str(self.prefix),
            EESSI_CVMFS_REPO=str(self.root / "repo"),
            PATH=f"{self.bins}:/usr/bin:/bin",
            FD_RECORD_DIR=str(self.records),
        )
        env.update(extra)
        return env

    def test_child_helpers_only_inherit_standard_streams(self):
        commands = [
            ("env-json", ["env", "--json"]),
            ("dev-json", ["dev", "--json", "zlib/1.3"]),
            ("dev-lock", ["dev", "--lock", "zlib/1.3"]),
            ("dev-locked-json", ["dev", "--locked", "--json"]),
        ]
        for label, args in commands:
            with self.subTest(mode=label):
                for f in self.records.glob("*.json"):
                    f.unlink()
                run = subprocess.run(
                    [binary.BIN, *args],
                    env=self.base_env(),
                    cwd=self.root,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                module_fds = json.loads((self.records / "module.json").read_text(encoding="utf-8"))
                self.assertEqual(module_fds, [0, 1, 2])
                if (self.records / "guard.json").exists():
                    guard_fds = json.loads((self.records / "guard.json").read_text(encoding="utf-8"))
                    self.assertEqual(guard_fds, [0, 1, 2])
                self.assertEqual(list(self.tmp_scratch.iterdir()), [])

    def test_failed_eval_with_background_child_does_not_hang_or_leave_tempdir(self):
        for label, args in (("env-json", ["env", "--json"]), ("dev-lock", ["dev", "--lock", "zlib/1.3"])):
            with self.subTest(mode=label):
                bg_pid_file = self.root / f"{label}.bg.pid"
                if bg_pid_file.exists():
                    bg_pid_file.unlink()
                try:
                    run = subprocess.run(
                        [binary.BIN, *args],
                        env=self.base_env(FAIL_WITH_BG="1", BG_PID_FILE=str(bg_pid_file)),
                        cwd=self.root,
                        capture_output=True,
                        text=True,
                        timeout=3,
                    )
                finally:
                    if bg_pid_file.exists():
                        try:
                            os.kill(int(bg_pid_file.read_text(encoding="utf-8")), signal.SIGKILL)
                        except OSError:
                            pass
                self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                self.assertEqual(list(self.tmp_scratch.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
