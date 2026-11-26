"""Shared helpers for hostile destination tests (full tmpfs, read-only parents, dangling symlinks)."""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


@contextmanager
def readonly_dir(path):
    """Temporarily make directory PATH read-only (0o555) and restore its mode on exit."""
    target = Path(path)
    previous = target.stat().st_mode & 0o7777
    target.chmod(0o555)
    try:
        yield target
    finally:
        target.chmod(previous)


def dangling_symlink(link_path, target_path):
    """Create a dangling symlink at LINK_PATH pointing to absent TARGET_PATH."""
    link = Path(link_path)
    target = Path(target_path)
    if target.exists() or target.is_symlink():
        raise AssertionError(f"expected absent symlink target: {target}")
    link.symlink_to(target)
    return link, target


def oversized_file(path, size_bytes, *, fill=None, mode=0o600):
    """Create a file of SIZE_BYTES at PATH (sparse when FILL is None) with MODE."""
    target = Path(path)
    with open(target, "wb") as handle:
        if fill is None:
            handle.truncate(size_bytes)
        else:
            if not fill:
                raise ValueError("fill must be non-empty bytes")
            block = (fill * ((4096 // len(fill)) + 1))[:4096]
            remaining = size_bytes
            while remaining > 0:
                piece = block[:remaining]
                handle.write(piece)
                remaining -= len(piece)
    target.chmod(mode)
    return target


def _mount_cmd():
    return shutil.which("mount") or "/bin/mount"


def _umount_cmd():
    return shutil.which("umount") or "/bin/umount"


def enter_full_tmpfs(test_case):
    """Return a full 64 KiB tmpfs Path inside an isolated user/mount namespace.

    Outside that namespace, re-runs TEST_CASE inside `unshare -r -m` and returns
    None after verifying the inner test run passed (or skips when unshare or
    tmpfs mounts are unavailable).
    """
    active = os.environ.get("EB_LOCAL_FULL_TMPFS_DIR")
    if active:
        return Path(active)

    unshare = shutil.which("unshare")
    if not unshare:
        test_case.skipTest("unshare unavailable")

    mount_bin = _mount_cmd()
    umount_bin = _umount_cmd()
    probe = subprocess.run(
        [
            unshare,
            "-r",
            "-m",
            "/bin/sh",
            "-c",
            f'd=$(mktemp -d) && "{mount_bin}" -t tmpfs -o size=64k tmpfs "$d" && "{umount_bin}" "$d" && rmdir "$d"',
        ],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        test_case.skipTest("user-namespace tmpfs mounts unavailable")

    tests_dir = str(Path(__file__).resolve().parent)
    repo_root = str(Path(__file__).resolve().parents[1])
    existing_pp = os.environ.get("PYTHONPATH", "")
    pp_parts = [tests_dir, repo_root] + ([existing_pp] if existing_pp else [])
    child_env = dict(os.environ, PYTHONPATH=":".join(pp_parts))

    run = subprocess.run(
        [unshare, "-r", "-m", sys.executable, str(Path(__file__).resolve()), test_case.id()],
        env=child_env,
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        test_case.fail(run.stdout + run.stderr)
    return None


def _run_inside_namespace(test_id):
    mount_bin = _mount_cmd()
    umount_bin = _umount_cmd()
    with tempfile.TemporaryDirectory(prefix="eb-local-tmpfs-") as tmp:
        mnt = Path(tmp) / "mnt"
        mnt.mkdir()
        subprocess.run([mount_bin, "-t", "tmpfs", "-o", "size=64k", "tmpfs", str(mnt)], check=True)
        try:
            try:
                with open(mnt / "fill", "wb") as handle:
                    while True:
                        handle.write(b"x" * 4096)
            except OSError:
                pass
            child_env = dict(os.environ, EB_LOCAL_FULL_TMPFS_DIR=str(mnt))
            proc = subprocess.run([sys.executable, "-m", "unittest", test_id], env=child_env)
            return proc.returncode
        finally:
            subprocess.run([umount_bin, str(mnt)], check=False)


if __name__ == "__main__":
    raise SystemExit(_run_inside_namespace(sys.argv[1]))
