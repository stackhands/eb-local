"""Run the command-line tests against the Zig build when EB_LOCAL_BIN names it.

The Bash tests replace findmnt and stat with shell functions. The binary
reads /proc/self/mountinfo and stats the job mount itself, so for it the
same controls become a mount table file (EB_LOCAL_TEST_MOUNTINFO) and a uid
(EB_LOCAL_TEST_UID), which only its -Dtest-ops test artifact reads. module
and eb stay shell functions: the binary runs them in a bash child, which
reads BASH_ENV as the script did. A build execs eb, and exec runs only a
program, so a program named eb, first on PATH, runs the eb function.
"""
import os
from pathlib import Path

BIN = os.environ.get("EB_LOCAL_BIN")


def _escape(path):
    return "".join("\\%03o" % ord(c) if c in " \t\n\\" else c for c in path)


def command(script, arguments, env):
    """argv and environment that run `arguments` through the tool under test."""
    if not BIN:
        return ["bash", str(script)] + list(arguments), env
    env = dict(env)
    # The release binary drops BASH_ENV (it is code bash runs before the
    # script). The test artifact sources this instead, and only then.
    prelude = env.pop("BASH_ENV", None)
    if prelude:
        env["EB_LOCAL_TEST_PRELUDE"] = prelude
        shims = Path(prelude).parent / "doubles-bin"
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
    return [BIN] + list(arguments), env
