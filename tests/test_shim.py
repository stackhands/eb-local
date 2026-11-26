#!/usr/bin/env python3
"""The repository command delegates to the Zig implementation unchanged."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary


SHIM = Path(__file__).resolve().parents[1] / "eb-local"
DOUBLE = """#!/bin/sh
[ "$#" -eq 4 ] || exit 90
[ "$1" = "word with spaces" ] || exit 91
[ "$2" = "quote'word" ] || exit 92
[ "$3" = "line
break" ] || exit 93
[ "$4" = "--flag=value" ] || exit 94
printf 'binary stdout\\n'
printf 'binary stderr\\n' >&2
exit 37
"""


class ShimDelegation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-shim-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shim = self.root / "eb-local"
        self.shim.write_bytes(SHIM.read_bytes())
        self.shim.chmod(0o755)

    @staticmethod
    def write_double(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(DOUBLE)
        path.chmod(0o755)

    def run_shim(self, path):
        env = dict(os.environ, PATH=path)
        env.pop("EB_LOCAL_CONFIG", None)
        return subprocess.run(
            [self.shim, "word with spaces", "quote'word", "line\nbreak", "--flag=value"],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def assert_delegated(self, run):
        self.assertEqual(run.returncode, 37, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "binary stdout\n")
        self.assertEqual(run.stderr, "binary stderr\n")

    def test_zig_build_gets_argv_and_passes_streams_and_status(self):
        self.write_double(self.root / "zig-out" / "bin" / "eb-local")
        self.assert_delegated(self.run_shim(""))

    def test_path_is_used_after_the_zig_build_location(self):
        path_bin = self.root / "path-bin"
        self.write_double(path_bin / "eb-local")
        self.assert_delegated(self.run_shim(str(path_bin)))

    def test_symlinked_shim_finds_the_real_checkouts_zig_build(self):
        links = self.root / "links"
        links.mkdir()
        linked = links / "eb-local"
        linked.symlink_to(self.shim)
        self.write_double(self.root / "zig-out" / "bin" / "eb-local")
        run = subprocess.run(
            [linked, "word with spaces", "quote'word", "line\nbreak", "--flag=value"],
            env=dict(os.environ, PATH=""),
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assert_delegated(run)

    def test_two_shim_copies_on_path_terminate(self):
        first = self.root / "first"
        second = self.root / "second"
        for directory in (first, second):
            directory.mkdir()
            copy = directory / "eb-local"
            copy.write_bytes(SHIM.read_bytes())
            copy.chmod(0o755)
        run = subprocess.run(
            [first / "eb-local", "--version"],
            env=dict(os.environ, PATH=f"{first}:{second}"),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(run.returncode, 127, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn(f"  PATH directory: {first}\n", run.stderr)
        self.assertIn(f"  PATH directory: {second}\n", run.stderr)

    def test_nested_call_from_zig_reenters_without_inherited_guard(self):
        nested = self.root / "zig-out" / "bin" / "eb-local"
        nested.parent.mkdir(parents=True)
        nested.write_text(
            """#!/bin/sh
if [ "$1" = nested ]; then
    printf 'nested call\\n'
    exit 23
fi
exec eb-local nested
"""
        )
        nested.chmod(0o755)
        run = subprocess.run(
            [self.shim, "outer"],
            env=dict(os.environ, PATH=str(self.root)),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(run.returncode, 23, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "nested call\n")
        self.assertEqual(run.stderr, "")

    def test_shim_does_not_set_or_mutate_eb_local_config(self):
        config = self.root / "eb-local.conf"
        config.write_text("node_local_root = /local\n", encoding="utf-8")
        zig = self.root / "zig-out" / "bin" / "eb-local"
        zig.parent.mkdir(parents=True)
        zig.write_text("#!/bin/sh\nprintf '%s\\n' \"${EB_LOCAL_CONFIG-unset}\"\n", encoding="utf-8")
        zig.chmod(0o755)
        env = dict(os.environ, PATH="")
        env.pop("EB_LOCAL_CONFIG", None)
        run = subprocess.run(
            [self.shim, "config"],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "unset\n")
        self.assertEqual(run.stderr, "")

        for given in ("", "/custom/site.toml"):
            run_given = subprocess.run(
                [self.shim, "config"],
                env=dict(env, EB_LOCAL_CONFIG=given),
                cwd=self.root,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run_given.returncode, 0, run_given.stdout + run_given.stderr)
            self.assertEqual(run_given.stdout, f"{given}\n")

    @unittest.skipUnless(binary.ZIG, "checkout delegation end-to-end uses the Zig binary")
    def test_shim_delegates_to_zig_without_exporting_eb_local_config(self):
        config = self.root / "eb-local.conf"
        config.write_text("node_local_root = /local/via-zig\n", encoding="utf-8")
        config.chmod(0o600)
        zig = self.root / "zig-out" / "bin" / "eb-local"
        zig.parent.mkdir(parents=True)
        shutil.copy2(binary.ZIG, zig)
        zig.chmod(0o755)

        guard_bin = self.root / "guard-bin"
        guard_bin.mkdir()
        seen = self.root / "guard-env.txt"
        guard = guard_bin / "eessi-arch-guard"
        guard.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"${{EB_LOCAL_CONFIG-unset}}\" > '{seen}'\n"
            "printf 'export EESSI_SOFTWARE_SUBDIR=x86_64/generic\\n'\n",
            encoding="utf-8",
        )
        guard.chmod(0o755)

        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("EB_LOCAL_")
        }
        env.update(
            HOME=str(self.root / "home"),
            XDG_CONFIG_HOME=str(self.root / "xdg"),
            SLURM_JOB_ID="1",
            EESSI_SOFTWARE_SUBDIR="x86_64/generic",
            PATH=f"{guard_bin}:/usr/bin:/bin",
        )
        (self.root / "home").mkdir()

        cfg = subprocess.run([self.shim, "config", "--json"], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(cfg.returncode, 0, cfg.stdout + cfg.stderr)
        rows = {row["key"]: row for row in json.loads(cfg.stdout)["settings"]}
        self.assertEqual(rows["storage.node_local_root"]["value"], "/local/via-zig")
        self.assertEqual(rows["storage.node_local_root"]["from"], f"site {config}:1")

        subprocess.run([self.shim, "doctor"], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(seen.read_text(encoding="utf-8"), "unset\n")

    def test_path_symlink_to_the_same_shim_is_skipped(self):
        path_bin = self.root / "path-bin"
        path_bin.mkdir()
        (path_bin / "eb-local").symlink_to(self.shim)
        run = subprocess.run(
            [self.shim, "--version"],
            env=dict(os.environ, PATH=str(path_bin)),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(run.returncode, 127, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertNotIn("recursive", run.stderr)
        self.assertIn(f"  PATH directory: {path_bin}\n", run.stderr)

    def test_missing_binary_names_every_location_and_exits_nonzero(self):
        first = self.root / "first"
        missing = self.root / "missing"
        first.mkdir()
        run = subprocess.run(
            [self.shim, "ignored"],
            env=dict(os.environ, PATH=f"{first}:{missing}"),
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 127)
        self.assertEqual(run.stdout, "")
        self.assertEqual(
            run.stderr,
            "eb-local: Zig binary not found\n"
            f"  real script directory: {self.root}\n"
            f"  Zig build: {self.root}/zig-out/bin/eb-local\n"
            f"  PATH directory: {first}\n"
            f"  PATH directory: {missing}\n",
        )


if __name__ == "__main__":
    unittest.main()
