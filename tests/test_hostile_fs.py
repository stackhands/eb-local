#!/usr/bin/env python3
"""Tests for shared hostile filesystem helpers in tests/hostile_fs.py."""
from pathlib import Path
import stat
import tempfile
import unittest

import hostile_fs


class HostileFsHelpers(unittest.TestCase):
    def test_readonly_dir_and_dangling_symlink_restore_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sub = root / "ro"
            sub.mkdir(mode=0o755)
            with hostile_fs.readonly_dir(sub):
                self.assertEqual(sub.stat().st_mode & 0o777, 0o555)
            self.assertEqual(sub.stat().st_mode & 0o777, 0o755)

            link, target = hostile_fs.dangling_symlink(root / "lnk", root / "absent")
            self.assertTrue(link.is_symlink())
            self.assertFalse(target.exists())

    def test_enter_full_tmpfs_provides_full_mount_and_cleans_up(self):
        mnt = hostile_fs.enter_full_tmpfs(self)
        if mnt is None:
            return
        with self.assertRaises(OSError):
            with open(mnt / "probe", "wb") as handle:
                handle.write(b"x" * 4096)

    def test_oversized_file_creates_sparse_and_filled_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sparse = hostile_fs.oversized_file(root / "sparse.bin", 131072)
            self.assertEqual(sparse.stat().st_size, 131072)
            self.assertEqual(stat.S_IMODE(sparse.stat().st_mode), 0o600)

            filled = hostile_fs.oversized_file(root / "filled.bin", 70000, fill=b"a", mode=0o600)
            self.assertEqual(filled.stat().st_size, 70000)
            self.assertEqual(filled.read_bytes()[:64], b"a" * 64)


if __name__ == "__main__":
    unittest.main()
