#!/usr/bin/env python3
from __future__ import annotations
import argparse
import errno
import os
import pathlib
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass

OPT_RE = re.compile(r"--[a-zA-Z0-9][a-zA-Z0-9-]*")
BRACED_CMDS_RE = re.compile(r"\{([a-z0-9][a-z0-9-]*(?:,[a-z0-9][a-z0-9-]*)+)\}")
HELP_ROW_RE = re.compile(r"^\s{2}([a-z][a-z0-9-]*)\s{2,}\S")
SKIP_CMDS = {"completion", "completions"}


@dataclass
class Tool:
    name: str
    command: list[str]


def run_help(argv: list[str]) -> str:
    cp = subprocess.run(argv + ["--help"], check=False, capture_output=True, text=True)
    if cp.returncode != 0:
        raise RuntimeError(f"{' '.join(shlex.quote(x) for x in argv + ['--help'])} failed: {cp.stderr.strip()}")
    return cp.stdout


def parse_subcommands(help_text: str, tool_name: str) -> list[str]:
    out: set[str] = set()
    for m in BRACED_CMDS_RE.finditer(help_text):
        for item in m.group(1).split(","):
            item = item.strip()
            if item and item not in SKIP_CMDS:
                out.add(item)
    usage_re = re.compile(
        rf"^\s{{2}}{re.escape(tool_name)}(?:\s+\[OPTION\]\.\.\.)?\s+([a-z][a-z0-9-]*)(?:\s+(?:\[([^\]]+)\]|([a-z][a-z0-9-]*)))?"
    )
    for line in help_text.splitlines():
        um = usage_re.match(line)
        if um:
            cmd = um.group(1)
            if cmd not in SKIP_CMDS:
                out.add(cmd)
            if um.group(2) and "|" in um.group(2):
                for part in um.group(2).split("|"):
                    tok = part.strip().split()[0] if part.strip() else ""
                    if re.fullmatch(r"[a-z][a-z0-9-]*", tok) and tok not in SKIP_CMDS:
                        out.add(tok)
            elif um.group(3) and um.group(3) not in SKIP_CMDS:
                out.add(um.group(3))
            continue
        rm = HELP_ROW_RE.match(line)
        if rm:
            item = rm.group(1)
            if item != tool_name and item not in SKIP_CMDS:
                out.add(item)
    return sorted(out)


def gather_words(tool: Tool) -> list[str]:
    words: set[str] = set()
    top_help = run_help(tool.command)
    words.update(OPT_RE.findall(top_help))
    subs = parse_subcommands(top_help, tool.name)
    for sub in subs:
        words.add(sub)
        try:
            sub_help = run_help(tool.command + [sub])
        except RuntimeError:
            continue
        words.update(OPT_RE.findall(sub_help))

    words.add("--help")
    return sorted(words)


def esc_roff(text: str) -> str:
    out = text.replace('\\', r'\\').replace('-', r'\-')
    if out.startswith(('.', "'")):
        out = r'\&' + out
    return out


def write_atomic_bytes(path: pathlib.Path, data: bytes) -> None:
    if os.environ.get("EB_LOCAL_TEST_CLI_ASSETS_WRITE") == "ENOSPC":
        raise OSError(errno.ENOSPC, "No space left on device", str(path))
    if path.is_symlink():
        raise OSError(f"refusing to replace symlink: {path}")
    try:
        st = path.lstat()
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISREG(st.st_mode):
            raise OSError(f"destination is not a regular file: {path}")

    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            view = memoryview(data)
            while view:
                written = handle.write(view)
                view = view[written:]
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def write_tracked_text(
    path: pathlib.Path,
    text: str,
    history: list[tuple[pathlib.Path, bytes | None]],
) -> None:
    if path.is_symlink():
        raise OSError(f"refusing to replace symlink: {path}")
    try:
        st = path.lstat()
    except FileNotFoundError:
        prior: bytes | None = None
    else:
        if not stat.S_ISREG(st.st_mode):
            raise OSError(f"destination is not a regular file: {path}")
        prior = path.read_bytes()
    write_atomic_bytes(path, text.encode("utf-8"))
    history.append((path, prior))


def ensure_dir(path: pathlib.Path, created_dirs: list[pathlib.Path]) -> None:
    if path.is_symlink():
        raise OSError(f"refusing to write under symlink: {path}")
    missing: list[pathlib.Path] = []
    probe = path
    while not probe.exists() and not probe.is_symlink():
        missing.append(probe)
        if probe.parent == probe:
            break
        probe = probe.parent
    path.mkdir(parents=True, exist_ok=True)
    for d in reversed(missing):
        if d.exists():
            created_dirs.append(d)


def rollback_writes(
    history: list[tuple[pathlib.Path, bytes | None]],
    created_dirs: list[pathlib.Path],
) -> None:
    for path, prior in reversed(history):
        try:
            if prior is None:
                path.unlink(missing_ok=True)
            else:
                write_atomic_bytes(path, prior)
        except OSError:
            pass
    for d in reversed(created_dirs):
        try:
            d.rmdir()
        except OSError:
            pass


def write_tool_assets(
    tool: Tool,
    out_dir: pathlib.Path,
    history: list[tuple[pathlib.Path, bytes | None]] | None = None,
    created_dirs: list[pathlib.Path] | None = None,
) -> None:
    words = gather_words(tool)
    words_str = " ".join(words)
    comps = out_dir / "completions"
    man = out_dir / "man"
    local_history: list[tuple[pathlib.Path, bytes | None]] = [] if history is None else history
    local_dirs: list[pathlib.Path] = [] if created_dirs is None else created_dirs

    try:
        ensure_dir(comps, local_dirs)
        ensure_dir(man, local_dirs)

        fn_name = "_" + re.sub(r"[^a-zA-Z0-9_]", "_", tool.name)
        bash = f"""# generated by tools/cli_assets.py; do not edit\n{fn_name}() {{\n  local cur\n  cur=\"${{COMP_WORDS[COMP_CWORD]}}\"\n  COMPREPLY=( $(compgen -W {shlex.quote(words_str)} -- \"$cur\") )\n}}\ncomplete -F {fn_name} {tool.name}\n"""
        write_tracked_text(comps / f"{tool.name}.bash", bash, local_history)

        zsh = f"""#compdef {tool.name}\n# generated by tools/cli_assets.py; do not edit\nlocal -a _opts\n_opts=({" ".join(shlex.quote(w) for w in words)})\n_describe 'values' _opts\n"""
        write_tracked_text(comps / f"_{tool.name}", zsh, local_history)

        fish_lines = [
            "# generated by tools/cli_assets.py; do not edit",
        ]
        for w in words:
            fish_lines.append(f"complete -c {tool.name} -f -a {shlex.quote(w)}")
        write_tracked_text(comps / f"{tool.name}.fish", "\n".join(fish_lines) + "\n", local_history)

        top_help = run_help(tool.command)
        first = top_help.splitlines()[0] if top_help.splitlines() else f"{tool.name} command"
        man_text = [
            f".TH {tool.name.upper()} 1",
            ".SH NAME",
            f"{tool.name} \\- autogenerated command reference",
            ".SH SUMMARY",
            ".nf",
            esc_roff(first),
            ".fi",
            ".SH HELP",
            ".nf",
        ]
        man_text.extend(esc_roff(line) for line in top_help.splitlines())
        man_text.extend([".fi", ""])
        write_tracked_text(man / f"{tool.name}.1", "\n".join(man_text), local_history)
    except Exception:
        if history is None:
            rollback_writes(local_history, local_dirs)
        raise


def parse_tool(spec: str) -> Tool:
    if "::" not in spec:
        raise ValueError("tool spec must be NAME::COMMAND")
    name, cmd = spec.split("::", 1)
    name = name.strip()
    if not name:
        raise ValueError("tool name is empty")
    argv = shlex.split(cmd)
    if not argv:
        raise ValueError("tool command is empty")
    return Tool(name=name, command=argv)


def generate(tools: list[Tool], out_dir: pathlib.Path) -> None:
    history: list[tuple[pathlib.Path, bytes | None]] = []
    created_dirs: list[pathlib.Path] = []
    try:
        for tool in tools:
            write_tool_assets(tool, out_dir, history=history, created_dirs=created_dirs)
    except Exception:
        rollback_writes(history, created_dirs)
        raise


def check_repro(tools: list[Tool]) -> None:
    with tempfile.TemporaryDirectory(prefix="cli-assets-a-") as a, tempfile.TemporaryDirectory(prefix="cli-assets-b-") as b:
        pa = pathlib.Path(a)
        pb = pathlib.Path(b)
        generate(tools, pa)
        generate(tools, pb)
        aa = sorted(p.relative_to(pa) for p in pa.rglob("*") if p.is_file())
        bb = sorted(p.relative_to(pb) for p in pb.rglob("*") if p.is_file())
        if aa != bb:
            raise RuntimeError("generated file set is not stable")
        for rel in aa:
            if (pa / rel).read_bytes() != (pb / rel).read_bytes():
                raise RuntimeError(f"generated content is not stable for {rel}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path, help="output directory")
    ap.add_argument("--tool", action="append", default=[], help="NAME::COMMAND")
    ap.add_argument("--check-repro", action="store_true")
    ns = ap.parse_args()

    if not ns.tool:
        ap.error("at least one --tool is required")
    try:
        tools = [parse_tool(spec) for spec in ns.tool]

        if ns.check_repro:
            check_repro(tools)
            return 0

        if ns.out is None:
            ap.error("--out is required unless --check-repro is set")
        generate(tools, ns.out)
        return 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"cli_assets: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
