#!/usr/bin/env python3
"""Read-only subdirectories inside temporary dirs are cleaned on error paths."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary

FD_AND_RO_HELPER = r'''#!/usr/bin/env python3
import json, os, sys

mode = sys.argv[1]
args = sys.argv[2:]

names = os.listdir("/proc/self/fd")
open_fds = sorted(int(n) for n in names if os.path.lexists(f"/proc/self/fd/{n}"))
fd_out = os.environ["FD_RECORD_DIR"] + f"/{mode}.json"
with open(fd_out, "w", encoding="utf-8") as fh:
    json.dump(open_fds, fh)

if mode == "guard":
    target_dir = os.environ["EESSI_ARCH_GUARD_WORKDIR"]
elif mode == "mpicc":
    out_idx = args.index("-o") + 1
    target_dir = os.path.dirname(args[out_idx])
elif mode == "module":
    target_dir = os.path.dirname(os.environ["LMOD_RC"])
else:
    raise RuntimeError(mode)

ro = os.path.join(target_dir, "readonly-cache")
os.makedirs(ro, exist_ok=True)
locked = os.path.join(ro, "artifact.dat")
with open(locked, "w", encoding="utf-8") as fh:
    fh.write("data\n")
os.chmod(locked, 0o400)
os.chmod(ro, 0o500)
sys.stderr.write(f"{mode} intentional failure\n")
sys.exit(7)
'''


@unittest.skipUnless(binary.BIN, "temporary directory cleanup belongs to the Zig binary")
class TempdirReadonlyCleanupCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-ro-tmp-")
        self.addCleanup(self.cleanup_readonly_and_tmp)
        self.root = Path(self.tmp.name).resolve()
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        self.records = self.root / "records"
        self.records.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.bins = self.root / "bins"
        self.bins.mkdir()

        helper = self.root / "ro-helper.py"
        helper.write_text(FD_AND_RO_HELPER, encoding="utf-8")
        helper.chmod(0o755)
        self.helper = helper

    def cleanup_readonly_and_tmp(self):
        for p in sorted(self.root.rglob("*"), reverse=True):
            try:
                if p.is_dir() and not p.is_symlink():
                    p.chmod(0o700)
                elif not p.is_symlink():
                    p.chmod(0o600)
            except OSError:
                pass
        self.tmp.cleanup()

    def write_wrapper(self, name: str, mode: str):
        w = self.bins / name
        w.write_text(
            f"#!/bin/sh\nexec python3 '{self.helper}' '{mode}' \"$@\"\n",
            encoding="utf-8",
        )
        w.chmod(0o755)

    def base_env(self, **extra):
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("EB_LOCAL_") and not k.startswith("EESSI_")
        }
        env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.root / "xdg"),
            TMPDIR=str(self.scratch),
            FD_RECORD_DIR=str(self.records),
            PATH=f"{self.bins}:/usr/bin:/bin",
        )
        env.update(extra)
        return env

    def test_doctor_guard_failure_cleans_readonly_tempdir_and_keeps_fds_clean(self):
        self.write_wrapper("eessi-arch-guard", "guard")
        subprocess.run(
            [binary.BIN, "doctor"],
            env=self.base_env(
                SLURM_JOB_ID="42",
                EESSI_SOFTWARE_SUBDIR="x86_64/generic",
            ),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )
        fds = json.loads((self.records / "guard.json").read_text(encoding="utf-8"))
        self.assertEqual(fds, [0, 1, 2])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_doctor_mpi_compile_failure_cleans_readonly_tempdir_and_keeps_fds_clean(self):
        self.write_wrapper("mpicc", "mpicc")
        mpirun = self.bins / "mpirun"
        mpirun.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        mpirun.chmod(0o755)
        fi_info = self.bins / "fi_info"
        fi_info.write_text("#!/bin/sh\necho 'provider: tcp'\n", encoding="utf-8")
        fi_info.chmod(0o755)

        site = self.root / "site.toml"
        site.write_text(
            '[storage]\nnode_local_root = "/local"\n[doctor]\nmpi_transports = ["ofi"]\n',
            encoding="utf-8",
        )
        site.chmod(0o600)

        subprocess.run(
            [binary.BIN, "--config", str(site), "doctor", "--mpi"],
            env=self.base_env(SLURM_JOB_ID="42"),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )
        fds = json.loads((self.records / "mpicc.json").read_text(encoding="utf-8"))
        self.assertEqual(fds, [0, 1, 2])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_lmod_cache_verify_failure_cleans_readonly_verify_dir_and_keeps_fds_clean(self):
        self.write_wrapper("module", "module")
        spider = self.root / "spider"
        spider.write_text("#!/bin/sh\nprintf 'spiderT = {}\\n'\n", encoding="utf-8")
        spider.chmod(0o755)
        modules = self.root / "modules"
        modules.mkdir()
        cache_dir = self.root / "existing-cache"
        cache_dir.mkdir()
        stamp = self.root / "system.txt"

        run = subprocess.run(
            [
                binary.BIN,
                "lmod-cache",
                "--verify",
                "--modulepath",
                str(modules),
                "--cache-dir",
                str(cache_dir),
                "--timestamp",
                str(stamp),
                "--spider",
                str(spider),
            ],
            env=self.base_env(SLURM_JOB_ID=""),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(run.returncode, 0)
        self.assertTrue((self.records / "module.json").is_file())
        self.assertEqual(list(cache_dir.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
