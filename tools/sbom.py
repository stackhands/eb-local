#!/usr/bin/env python3
"""Write a CycloneDX 1.6 SBOM for one eb-local release binary.

A static Zig binary carries no package metadata, so the SBOM is built from
what went into it: the Zig dependencies pinned in build.zig.zon, the Zig
toolchain, and the musl C library Zig links in statically. The output is
deterministic for the same inputs (no clock, no random serial number).

    sbom.py --binary dist/eb-local-2.3.0-x86_64-linux-musl \
            --zon build.zig.zon --zig 0.17.1 --commit 38b8fe5... > x.cdx.json
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import uuid

REPO = "stackhands/eb-local"
GITHUB = re.compile(r'^git\+https://github\.com/([\w.-]+/[\w.-]+?)(?:\.git)?#(.+)$')
DEP_HEAD = re.compile(r'\.(\w+)\s*=\s*\.\{')
URL_RE = re.compile(r'\.url\s*=\s*"([^"]+)"')
HASH_RE = re.compile(r'\.hash\s*=\s*"([^"]+)"')


def _brace_block(text, open_brace_idx):
    depth = 0
    in_str = False
    esc = False
    for i in range(open_brace_idx, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    return text[open_brace_idx + 1 : i], i + 1
    return None, len(text)


def _strip_comments(text):
    out = []
    in_str = False
    esc = False
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if in_str:
            out.append(ch)
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            i += 1
        elif ch == '"':
            in_str = True
            out.append(ch)
            i += 1
        elif ch == "/" and i + 1 < n and text[i + 1] == "/":
            nl = text.find("\n", i)
            if nl == -1:
                break
            i = nl
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def zon_field(text, field):
    text = _strip_comments(text)
    m = re.search(r'^\s*\.' + field + r'\s*=\s*"([^"]+)"', text, re.M)
    if not m:
        raise SystemExit(f"build.zig.zon has no .{field}")
    return m.group(1)


def dependencies(text):
    text = _strip_comments(text)
    start = re.search(r'\.dependencies\s*=\s*\.\{', text)
    if not start:
        return []
    body, _ = _brace_block(text, start.end() - 1)
    if body is None:
        return []
    deps = []
    pos = 0
    while pos < len(body):
        m = DEP_HEAD.search(body, pos)
        if not m:
            break
        name = m.group(1)
        entry, pos = _brace_block(body, m.end() - 1)
        if entry is None:
            break
        um = URL_RE.search(entry)
        hm = HASH_RE.search(entry)
        if not um or not hm:
            continue
        url, zhash = um.group(1), hm.group(1)
        gm = GITHUB.match(url)
        if not gm:
            raise SystemExit(f"dependency {name}: cannot name {url} as a package URL")
        repo, ref = gm.groups()
        version = ref[1:] if re.fullmatch(r'v\d.*', ref) else ref
        deps.append({
            "type": "library",
            "bom-ref": f"pkg:github/{repo}@{ref}",
            "name": repo.split("/")[1],
            "version": version,
            "purl": f"pkg:github/{repo}@{ref}",
            "externalReferences": [{"type": "vcs", "url": f"https://github.com/{repo}"}],
            "properties": [{"name": "zig:package-hash", "value": zhash}],
        })
    return deps


def sbom(binary, zon_text, zig, commit):
    version = zon_field(zon_text, "version")
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    target = binary.name.split(f"eb-local-{version}-", 1)[-1]
    me = f"pkg:github/{REPO}@v{version}"
    deps = dependencies(zon_text)
    musl = {
        "type": "library",
        "bom-ref": "musl-libc",
        "name": "musl",
        "description": f"C library linked statically, as bundled with Zig {zig}",
        "externalReferences": [{"type": "website", "url": "https://musl.libc.org/"}],
        "licenses": [{"license": {"id": "MIT"}}],
    }
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, me + '#' + digest)}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": me,
                "name": "eb-local",
                "version": version,
                "purl": me,
                "hashes": [{"alg": "SHA-256", "content": digest}],
                "licenses": [{"license": {"id": "MIT"}}],
                "externalReferences": [{"type": "vcs", "url": f"https://github.com/{REPO}"}],
                "properties": [
                    {"name": "file", "value": binary.name},
                    {"name": "target", "value": target},
                    {"name": "commit", "value": commit},
                ],
            },
            "tools": {"components": [{
                "type": "application",
                "name": "zig",
                "version": zig,
                "externalReferences": [{"type": "website", "url": "https://ziglang.org/"}],
            }]},
        },
        "components": deps + [musl],
        "dependencies": [
            {"ref": me, "dependsOn": [d["bom-ref"] for d in deps] + ["musl-libc"]},
        ],
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--binary", required=True, type=Path)
    p.add_argument("--zon", required=True, type=Path)
    p.add_argument("--zig", required=True)
    p.add_argument("--commit", required=True)
    a = p.parse_args(argv)
    json.dump(sbom(a.binary, a.zon.read_text(), a.zig, a.commit), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
