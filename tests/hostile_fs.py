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
    try:
        probe = subprocess.run(
            [
                unshare,
                "-r",
                "-m",
                "/bin/sh",
                "-c",
                f'd=$(mktemp -d) && "{mount_bin}" -t tmpfs -o size=64k tmpfs "$d" && "{umount_bin}" "$d" && rmdir "$d"',
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        test_case.skipTest("user-namespace tmpfs mounts unavailable")
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
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if run.returncode != 0:
        test_case.fail(run.stdout + run.stderr)
    return None


def enter_without_host_paths(test_case, paths):
    """Ensure `/etc/...` PATHS are absent; re-runs TEST_CASE in a mount namespace if any exist.

    Returns True when the current process already lacks every path in PATHS (including inside
    the isolated re-invocation), and False after a delegated namespace run succeeds.
    """
    present = [str(p) for p in paths if Path(p).exists() or Path(p).is_symlink()]
    if not present:
        return True

    unshare = shutil.which("unshare")
    if not unshare:
        test_case.skipTest("unshare unavailable")

    mount_bin = _mount_cmd()
    umount_bin = _umount_cmd()
    uid = str(os.getuid())
    gid = str(os.getgid())
    try:
        probe = subprocess.run(
            [
                unshare,
                "-U",
                "--keep-caps",
                f"--map-user={uid}",
                f"--map-group={gid}",
                "-m",
                "/bin/sh",
                "-c",
                f'd=$(mktemp -d) && "{mount_bin}" --bind "$d" "$d" && "{umount_bin}" "$d" && rmdir "$d"',
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        test_case.skipTest("user-namespace bind mounts unavailable")
    if probe.returncode != 0:
        test_case.skipTest("user-namespace bind mounts unavailable")

    tests_dir = str(Path(__file__).resolve().parent)
    repo_root = str(Path(__file__).resolve().parents[1])
    existing_pp = os.environ.get("PYTHONPATH", "")
    pp_parts = [tests_dir, repo_root] + ([existing_pp] if existing_pp else [])
    child_env = dict(os.environ, PYTHONPATH=":".join(pp_parts))

    run = subprocess.run(
        [
            unshare,
            "-U",
            "--keep-caps",
            f"--map-user={uid}",
            f"--map-group={gid}",
            "-m",
            sys.executable,
            str(Path(__file__).resolve()),
            "--mask-etc",
            test_case.id(),
            *present,
        ],
        cwd=repo_root,
        env=child_env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if run.returncode != 0:
        test_case.fail(run.stdout + run.stderr)
    if "skipped=" in (run.stdout + run.stderr):
        test_case.fail(run.stdout + run.stderr)
    return False


def _run_without_etc_paths(test_id, masked_paths):
    mount_bin = _mount_cmd()
    umount_bin = _umount_cmd()
    with tempfile.TemporaryDirectory(prefix="eb-local-etc-mask-") as tmp:
        etc_copy = Path(tmp) / "etc"
        etc_copy.mkdir()
        subprocess.run(
            ["cp", "-a", "/etc/.", str(etc_copy)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=False,
            timeout=15,
        )
        for raw in masked_paths:
            p = Path(raw)
            rel = p.relative_to("/etc")
            target = etc_copy / rel
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink(missing_ok=True)
        subprocess.run([mount_bin, "--bind", str(etc_copy), "/etc"], check=True, timeout=10)
        try:
            proc = subprocess.run([sys.executable, "-m", "unittest", "-v", test_id], timeout=25)
            return proc.returncode
        finally:
            subprocess.run([umount_bin, "/etc"], check=False, timeout=10)


def _run_inside_namespace(test_id):
    mount_bin = _mount_cmd()
    umount_bin = _umount_cmd()
    with tempfile.TemporaryDirectory(prefix="eb-local-tmpfs-") as tmp:
        mnt = Path(tmp) / "mnt"
        mnt.mkdir()
        subprocess.run(
            [mount_bin, "-t", "tmpfs", "-o", "size=64k", "tmpfs", str(mnt)],
            check=True,
            timeout=10,
        )
        try:
            try:
                with open(mnt / "fill", "wb") as handle:
                    while True:
                        handle.write(b"x" * 4096)
            except OSError:
                pass
            child_env = dict(os.environ, EB_LOCAL_FULL_TMPFS_DIR=str(mnt))
            proc = subprocess.run(
                [sys.executable, "-m", "unittest", test_id],
                env=child_env,
                timeout=25,
            )
            return proc.returncode
        finally:
            subprocess.run([umount_bin, str(mnt)], check=False, timeout=10)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--mask-etc":
        raise SystemExit(_run_without_etc_paths(sys.argv[2], sys.argv[3:]))
    raise SystemExit(_run_inside_namespace(sys.argv[1]))
