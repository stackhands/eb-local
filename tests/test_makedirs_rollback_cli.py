"""CLI regression tests for rolling back newly created parent directories when `makedirs` fails."""

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary

SCRIPT = Path(__file__).resolve().parents[1] / "eb-local"


class MakedirsErrorRollbackCli(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.overlong = "a" * 260

    def test_lmod_cache_rolls_back_created_parent_on_makedirs_failure_and_keeps_existing_file(self):
        mod_dir = self.root / "modules/all"
        mod_dir.mkdir(parents=True)
        spider = self.root / "spider"
        spider.write_text("#!/bin/sh\nprintf 'spiderT = {}\\n'\n")
        spider.chmod(0o755)

        parent = self.root / "created-cache-parent"
        bad_cache_dir = parent / self.overlong
        stamp = self.root / "system.txt"
        argv, env = binary.command(
            SCRIPT,
            [
                "lmod-cache",
                "--modulepath",
                str(mod_dir),
                "--spider",
                str(spider),
                "--cache-dir",
                str(bad_cache_dir),
                "--timestamp",
                str(stamp),
            ],
            {"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
        )
        res = subprocess.run(
            argv,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(parent.exists(), f"lmod-cache leaked created parent directory: {parent}")

        # Pre-existing regular file blocking cache-dir must NOT be deleted by rollback.
        blocker = self.root / "existing-file"
        blocker.write_text("keep-me\n")
        argv, env = binary.command(
            SCRIPT,
            [
                "lmod-cache",
                "--modulepath",
                str(mod_dir),
                "--spider",
                str(spider),
                "--cache-dir",
                str(blocker / "sub"),
                "--timestamp",
                str(stamp),
            ],
            {"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
        )
        res_blocker = subprocess.run(
            argv,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(res_blocker.returncode, 0)
        self.assertTrue(blocker.is_file(), "rollback deleted a pre-existing regular file")
        self.assertEqual(blocker.read_text(), "keep-me\n")

    def test_modulerc_rolls_back_created_parent_on_makedirs_failure(self):
        parent = self.root / "created-modulerc-parent"
        bad_tree = parent / self.overlong
        argv, env = binary.command(
            SCRIPT,
            [
                "modulerc",
                "--module-tree",
                str(bad_tree),
                "--default",
                "zlib/1.3",
            ],
            {"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
        )
        res = subprocess.run(
            argv,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(parent.exists(), f"modulerc leaked created parent directory: {parent}")

    def test_overlay_materialize_rolls_back_created_parent_on_makedirs_failure(self):
        content = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
        base_eb = self.root / "base.eb"
        base_eb.write_bytes(content)
        overlay_toml = self.root / "site.overlay.toml"
        overlay_toml.write_text(
            f'overlay_version = 1\nbase_digest = "{hashlib.sha256(content).hexdigest()}"\n',
            encoding="utf-8",
        )
        parent = self.root / "created-overlay-parent"
        bad_out = parent / self.overlong
        argv, env = binary.command(
            SCRIPT,
            [
                "overlay",
                "materialize",
                "--overlay",
                str(overlay_toml),
                "--base",
                str(base_eb),
                "--out-dir",
                str(bad_out),
            ],
            {"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
        )
        res = subprocess.run(
            argv,
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(parent.exists(), f"overlay materialize leaked created parent directory: {parent}")

    def test_rpath_wrappers_rolls_back_created_parent_on_makedirs_failure(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        gcc = fake_bin / "gcc"
        gcc.write_text("#!/bin/sh\nexit 0\n")
        gcc.chmod(0o755)

        site = self.root / "site.toml"
        site.write_text('[storage]\nnode_local_root = "/local"\n', encoding="utf-8")
        site.chmod(0o600)

        parent = self.root / "created-xdg-parent"
        bad_xdg = parent / self.overlong
        argv, env = binary.command(
            SCRIPT,
            ["rpath-wrappers"],
            {
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "HOME": str(self.root),
                "XDG_CACHE_HOME": str(bad_xdg),
                "EB_LOCAL_CONFIG": str(site),
                "EB_LOCAL_PREFIX": str(self.root / "prefix"),
            },
        )
        res = subprocess.run(
            argv,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(parent.exists(), f"rpath-wrappers leaked created parent directory: {parent}")


if __name__ == "__main__":
    unittest.main()
