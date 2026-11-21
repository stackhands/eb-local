"""Shared scaffolding for the tests that break standard output on purpose.

A Scene is one temporary tree with an install prefix and a PATH of doubles.
Nothing in it holds the prefix lock, so a command that took the lock before
it had written its plan shows up as a file in the snapshot.
"""

import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path

import binary

REPO = Path(__file__).resolve().parents[1]
BROKEN_SINKS = {
    "dev-full": "No space left on device",
    "closed": "Bad file descriptor",
    "closed-pipe": "Broken pipe",
}


def tool_path():
    path = binary.ZIG or str(binary.BUILT)
    if not os.access(path, os.X_OK):
        raise RuntimeError(f"no eb-local program at {path}; run zig build first")
    return path


def make_front_ends(root):
    """The program itself, and the shell shim over a copy of it."""
    shim_root = root / "shim"
    (shim_root / "zig-out" / "bin").mkdir(parents=True)
    (shim_root / "eb-local").write_bytes((REPO / "eb-local").read_bytes())
    (shim_root / "zig-out" / "bin" / "eb-local").symlink_to(tool_path())
    return {
        "zig": [tool_path()],
        "shell": ["/bin/sh", str(shim_root / "eb-local")],
    }


def run_with_stdout(argv, sink, *, env, cwd):
    common = dict(env=env, cwd=cwd, stdin=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
    if sink == "dev-full":
        with open("/dev/full", "wb") as full:
            return subprocess.run(argv, stdout=full, **common)
    if sink == "closed-pipe":
        reader, writer = os.pipe()
        os.close(reader)
        try:
            return subprocess.run(argv, stdout=writer, **common)
        finally:
            os.close(writer)
    if sink == "closed":
        return subprocess.run(
            ["/bin/sh", "-c", 'exec "$@" 1>&-', "sh", *argv], stdout=subprocess.PIPE, **common
        )
    return subprocess.run(argv, stdout=subprocess.PIPE, **common)


def snapshot(root):
    """Every path below root with its type, mode and content, links unfollowed."""
    state = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            path = Path(dirpath) / name
            rel = str(path.relative_to(root))
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                state[rel] = ("link", os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                state[rel] = ("dir", mode)
            else:
                state[rel] = ("file", mode, hashlib.sha256(path.read_bytes()).hexdigest())
    return state


def write_executable(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class Scene:
    """One temporary tree: an install prefix, a PATH of doubles, a site file."""

    def __init__(self, root, *, site="[storage]\n", make_prefix=True):
        self.root = root
        self.prefix = root / "prefix"
        self.bins = root / "bin"
        self.marker = root / "doubles.calls"
        self.bins.mkdir(parents=True)
        if make_prefix:
            self.prefix.mkdir()
        site_file = root / "site.toml"
        site_file.write_text(site, encoding="utf-8")
        site_file.chmod(0o600)
        self.env = {
            "PATH": f"{self.bins}:/usr/bin:/bin",
            "HOME": str(root),
            "XDG_CACHE_HOME": str(root / "cache"),
            "EB_LOCAL_CONFIG": str(site_file),
            "EB_LOCAL_PREFIX": str(self.prefix),
            "SLURM_JOB_ID": "",
            "LC_ALL": "C.UTF-8",
            "PYTHONUTF8": "1",
        }

    def old_log(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        log = logs / "easybuild-old.log"
        log.write_text("log\n", encoding="utf-8")
        os.utime(log, (1_000_000_000, 1_000_000_000))
        return log

    def demo_install(self):
        """Demo/1.0 for one CPU target, as EasyBuild leaves it: read-only."""
        target = self.prefix / "versions" / "2023.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        tree = target / "software" / "Demo" / "1.0"
        module = target / "modules" / "all" / "Demo" / "1.0.lua"
        (tree / "bin").mkdir(parents=True)
        (tree / "bin" / "demo").write_text("#!/bin/sh\n", encoding="utf-8")
        (tree / "bin" / "demo").chmod(0o555)
        module.parent.mkdir(parents=True)
        module.write_text("-- lua\n", encoding="utf-8")
        for directory in (tree / "bin", tree):
            directory.chmod(0o555)
        return tree, module

    def trashed_install(self):
        """Restored/1.0 in the trash, and an rtrash that lists it and records restores."""
        target = self.prefix / "versions" / "2023.06" / "software" / "linux" / "x86_64" / "intel" / "skylake_avx512"
        (target / "software").mkdir(parents=True)
        (target / "modules" / "all").mkdir(parents=True)
        listing = json.dumps(
            [
                {"original": str(target / "software" / "Restored" / "1.0"), "trash_dir": str(self.root / "trash")},
                {"original": str(target / "modules" / "all" / "Restored" / "1.0.lua"), "trash_dir": str(self.root / "trash")},
            ]
        )
        write_executable(
            self.bins / "rtrash",
            "#!/bin/sh\n"
            f"if [ \"$1\" = list ]; then printf '%s\\n' '{listing}'; exit 0; fi\n"
            f"printf '%s\\n' \"$*\" >> '{self.marker}'\n"
            "exit 0\n",
        )

    def recorder(self, name):
        """A program of that name that records its call in the marker and does nothing."""
        write_executable(
            self.bins / name,
            f"#!/bin/sh\nprintf '%s\\n' \"{name} $*\" >> '{self.marker}'\nexit 0\n",
        )

    def rtrash_recorder(self):
        self.recorder("rtrash")

    def calls(self):
        return self.marker.read_text(encoding="utf-8").splitlines() if self.marker.exists() else []
