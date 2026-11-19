"""Shared helpers for evaluating emitted shell code in real caller shells."""

import shutil
import subprocess


def available_shells():
    """Yield supported caller shells installed on this host."""
    for name in ("bash", "zsh"):
        path = shutil.which(name)
        if path:
            yield name, path


def run_shell(name, executable, script, *, env, cwd):
    """Run script in a clean interactive-shell-compatible process."""
    args = [executable]
    if name == "bash":
        args += ["--noprofile", "--norc"]
    else:
        args += ["-f"]
    return subprocess.run(
        args + ["-c", script],
        check=False,
        env=env,
        cwd=cwd,
        text=True,
        capture_output=True,
    )
