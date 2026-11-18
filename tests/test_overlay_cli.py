#!/usr/bin/env python3
"""`eb-local overlay` applies digest-pinned recipe overlays."""

import hashlib
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary


def digest_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(args, *, cwd=None, text=True):
    return subprocess.run(
        [binary.BIN, "overlay", *args],
        capture_output=True,
        cwd=cwd,
        text=text,
    )


@unittest.skipUnless(binary.BIN, "EB_LOCAL_BIN names the Zig build")
class OverlayMaterialize(unittest.TestCase):
    def test_default_output_and_status_are_unchanged_raw_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest_of(content)}"\n',
                encoding="utf-8",
            )
            got = run(
                [
                    "materialize",
                    "--overlay",
                    "site.overlay.toml",
                    "--base",
                    "base.eb",
                    "--out-dir",
                    "out",
                ],
                cwd=root,
                text=False,
            )
            self.assertEqual(
                (got.returncode, got.stdout, got.stderr),
                (0, b"wrote out/materialized-base.eb and out/provenance.toml\n", b""),
            )

    def test_dry_run_validates_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest_of(content)}"\n',
                encoding="utf-8",
            )
            got = run(
                [
                    "materialize",
                    "--overlay",
                    "site.overlay.toml",
                    "--base",
                    "base.eb",
                    "--out-dir",
                    "out",
                    "--dry-run",
                ],
                cwd=root,
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual(
                got.stdout,
                "would write out/materialized-base.eb and out/provenance.toml\n",
            )
            self.assertEqual(got.stderr, "")
            self.assertFalse((root / "out").exists())

    def test_pinned_overlay_without_edits_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "base.eb"
            content = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
            base.write_bytes(content)
            overlay = Path(tmp) / "site.overlay.toml"
            overlay.write_text(
                f'overlay_version = 1\n'
                f'base_digest = "{digest_of(content)}"\n'
                f'rationale = "pin only"\n',
                encoding="utf-8",
            )
            out = Path(tmp) / "out"
            out.mkdir()
            got = run(
                [
                    "materialize",
                    "--overlay",
                    str(overlay),
                    "--base",
                    str(base),
                    "--out-dir",
                    str(out),
                ]
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            recipe = out / "materialized-base.eb"
            self.assertEqual(recipe.read_bytes(), content)
            self.assertIn("provenance.toml", got.stdout)
            self.assertIn(str(recipe), got.stdout)

    def test_replaces_parameters_and_records_provenance(self):
        root = Path(__file__).resolve().parent / "fixtures" / "recipe_overlay"
        base = root / "base.eb"
        content = base.read_bytes()
        overlay = Path(tempfile.mkdtemp()) / "site.overlay.toml"
        overlay.write_text(
            f'overlay_version = 1\n'
            f'base_easyconfig = "base.eb"\n'
            f'base_digest = "{digest_of(content)}"\n'
            f'rationale = "site MPI"\n'
            f"\n[replace]\n"
            f'preconfigopts = "--with-slurm"\n'
            f"\n[patches]\n"
            f'site = "site-mpi.patch"\n'
            f"\n[dependencies.add]\n"
            f"zlib = \"('zlib', '1.2.13-GCCcore-13.3.0')\"\n",
            encoding="utf-8",
        )
        out = overlay.parent
        got = run(
            [
                "materialize",
                "--overlay",
                str(overlay),
                "--base",
                str(base),
                "--out-dir",
                str(out),
            ]
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        recipe = (out / "materialized-base.eb").read_text(encoding="utf-8")
        self.assertIn("preconfigopts = --with-slurm", recipe)
        self.assertIn("('site', 'site-mpi.patch')", recipe)
        self.assertIn("('zlib', '1.2.13-GCCcore-13.3.0')", recipe)
        prov = (out / "provenance.toml").read_text(encoding="utf-8")
        self.assertIn('rationale = """', prov)
        self.assertIn("site MPI", prov)
        self.assertIn(digest_of(content), prov)

    def test_refuses_when_base_digest_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "base.eb"
            base.write_text("easyblock = 'ConfigureMake'\n", encoding="utf-8")
            overlay = Path(tmp) / "site.overlay.toml"
            overlay.write_text(
                'overlay_version = 1\n'
                'base_digest = "0000000000000000000000000000000000000000000000000000000000000000"\n',
                encoding="utf-8",
            )
            got = run(
                [
                    "materialize",
                    "--overlay",
                    str(overlay),
                    "--base",
                    str(base),
                ]
            )
            self.assertEqual(got.returncode, 2, got.stdout)
            self.assertIn("base digest", got.stderr)

    def test_bump_forwards_to_eb_stack(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "eb-stack"
            stub.write_text(
                "#!/bin/sh\n"
                'printf "%s\\n" "$@"\n'
                'test "$1" = package && test "$2" = bump\n'
                "exit 0\n",
                encoding="utf-8",
            )
            stub.chmod(0o755)
            got = run(
                [
                    "bump",
                    "--eb-stack",
                    str(stub),
                    "--",
                    "--easyconfig",
                    "foo.eb",
                ]
            )
        self.assertEqual(got.returncode, 0, got.stderr)
        joined = got.stdout.replace("\n", " ")
        self.assertIn("package bump", joined)


@unittest.skipUnless(binary.BIN, "EB_LOCAL_BIN names the Zig build")
class OverlayDefaultOutput(unittest.TestCase):
    """Without overlay, build-related stdout stays unchanged."""

    @staticmethod
    def host_musl_target_triple() -> str:
        machine = platform.machine().lower()
        aliases = {"amd64": "x86_64", "arm64": "aarch64"}
        arch = aliases.get(machine, machine)
        return f"{arch}-linux-musl"

    def test_version_line_is_unchanged(self):
        run = subprocess.run([binary.BIN, "--version"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertRegex(
            run.stdout,
            rf"^eb-local 3\.1\.0 \({self.host_musl_target_triple()}",
        )


if __name__ == "__main__":
    unittest.main()