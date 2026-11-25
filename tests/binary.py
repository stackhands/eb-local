"""Run command-line tests through the shim or the Zig test build.

The fixtures replace findmnt and stat with shell functions. The binary
reads /proc/self/mountinfo and stats the job mount itself, so for it the
same controls become a mount table file (EB_LOCAL_TEST_MOUNTINFO) and a uid
(EB_LOCAL_TEST_UID), which only its -Dtest-ops test artifact reads. module
and eb stay shell functions: the binary runs them in a bash child. A build
execs eb, and exec runs only a
program, so a program named eb, first on PATH, runs the eb function. It
goes in the test's CONTROL_ROOT, beside the doubles: a BASH_ENV a test
passes on from its caller, such as Lmod's init, is in a directory the
test cannot write, and has no eb function for the program to run.
"""
import os
import shutil
from pathlib import Path

BIN = os.environ.get("EB_LOCAL_BIN")
SH = shutil.which("sh") or "/bin/sh"
BUILT = Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "eb-local"
# Where a copy of the shell shim finds the Zig program when a test sets its own PATH.
SHIM_PATH = "" if BIN else str(BUILT.parent)
# The Zig program the tests that name it run: the one EB_LOCAL_BIN names, else
# the one the shell shim delegates to.
ZIG = BIN or (str(BUILT) if BUILT.is_file() and os.access(BUILT, os.X_OK) else None)


def _escape(path):
    return "".join("\\%03o" % ord(c) if c in " \t\n\\" else c for c in path)


def command(script, arguments, env):
    """argv and environment that run `arguments` through the tool under test."""
    env = dict(env)
    if not BIN:
        env["PATH"] = f"{BUILT.parent}:{env.get('PATH', '/usr/bin:/bin')}"
    # The release binary drops BASH_ENV (it is code bash runs before the
    # script). The test artifact sources this instead, and only then.
    prelude = env.pop("BASH_ENV", None)
    if prelude:
        env["EB_LOCAL_TEST_PRELUDE"] = prelude
    if prelude and env.get("CONTROL_ROOT"):
        shims = Path(env["CONTROL_ROOT"]) / "doubles-bin"
        shims.mkdir(exist_ok=True)
        (shims / "eb").write_text('#!/bin/bash\ndeclare -F eb >/dev/null || { echo "no eb double" >&2; exit 127; }\neb "$@"\n')
        (shims / "eb").chmod(0o755)
        env["PATH"] = f"{shims}:{env.get('PATH', '/usr/bin:/bin')}"
    job = env.get("CONTROL_JOB_ROOT")
    if job:
        target = env.get("CONTROL_MOUNT_TARGET") or job
        fstype = env.get("CONTROL_FSTYPE") or "xfs"
        options = env.get("CONTROL_MOUNT_OPTIONS") or "rw,relatime"
        table = Path(env["CONTROL_ROOT"]) / "mountinfo"
        table.write_text(
            "1 0 0:1 / / rw - ext4 /dev/root rw\n"
            f"2 1 0:2 / {_escape(target)} {options} - {fstype} /dev/node rw\n")
        env["EB_LOCAL_TEST_MOUNTINFO"] = str(table)
    owner = env.get("CONTROL_OWNER")
    if owner:
        # The mount belongs to the caller; the caller is made someone else.
        env["EB_LOCAL_TEST_UID"] = str(os.getuid() + 1)
    program = [BIN] if BIN else [SH, str(script)]
    return program + list(arguments), env
