"""Benchmarks for command paths that inspect and plan real installations."""

import os
from pathlib import Path
import shutil
import subprocess


def setup_cache():
    root = Path.cwd()
    binary = Path(os.environ["EB_LOCAL_BENCH_BIN"]).resolve()
    site = Path(__file__).resolve().parents[1] / "examples" / "sites" / "example.toml"
    tree = root / "installation"
    for index in range(32):
        target = tree / f"package-{index}" / "1.0" / "bin" / "eb-local"
        target.parent.mkdir(parents=True)
        shutil.copy2(binary, target)
    home = root / "home"
    home.mkdir()
    return {
        "binary": str(binary),
        "home": str(home),
        "site": str(site),
        "tree": str(tree),
    }


def _run(cache, *arguments):
    env = {
        "HOME": cache["home"],
        "PATH": os.environ["PATH"],
        "XDG_CONFIG_HOME": str(Path(cache["home"]) / ".config"),
    }
    subprocess.run(
        [cache["binary"], *arguments],
        check=True,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def time_parse_site_configuration(cache):
    _run(cache, "--config", cache["site"], "config")


def time_export_build_environment(cache):
    _run(cache, "--config", cache["site"], "config", "--env")


def time_render_site_template(cache):
    _run(
        cache,
        "site",
        "show",
        "slurm",
        "--set",
        "node_local_root=/local",
        "--set",
        "shared_scratch=/scratch",
    )


def time_scan_installation_tree(cache):
    _run(cache, "check", "--prefix", cache["tree"], "--quiet")
