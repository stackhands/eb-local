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

            dry = run(
                [
                    "materialize",
                    "--overlay",
                    "site.overlay.toml",
                    "--base",
                    "base.eb",
                    "--out-dir",
                    "dry-out",
                    "--dry-run",
                ],
                cwd=root,
                text=False,
            )
            self.assertEqual(
                (dry.returncode, dry.stdout, dry.stderr),
                (0, b"would write dry-out/materialized-base.eb and dry-out/provenance.toml\n", b""),
            )
            self.assertFalse((root / "dry-out").exists())

    def test_check_reports_drift_without_creating_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest_of(content)}"\n',
                encoding="utf-8",
            )
            args = [
                "materialize",
                "--overlay",
                "site.overlay.toml",
                "--base",
                "base.eb",
                "--out-dir",
                "out",
            ]

            missing = run([*args, "--check"], cwd=root)
            self.assertEqual(
                (missing.returncode, missing.stdout, missing.stderr),
                (1, "would update out/materialized-base.eb and out/provenance.toml\n", ""),
            )
            self.assertFalse((root / "out").exists())

            wrote = run(args, cwd=root)
            self.assertEqual(wrote.returncode, 0, wrote.stderr)

            current = run([*args, "--check"], cwd=root)
            self.assertEqual(
                (current.returncode, current.stdout, current.stderr),
                (0, "up to date out/materialized-base.eb and out/provenance.toml\n", ""),
            )

            recipe = root / "out" / "materialized-base.eb"
            recipe.write_text("edited by hand\n", encoding="utf-8")
            drifted_recipe = run([*args, "--check"], cwd=root)
            self.assertEqual(
                (drifted_recipe.returncode, drifted_recipe.stdout, drifted_recipe.stderr),
                (1, "would update out/materialized-base.eb and out/provenance.toml\n", ""),
            )
            self.assertEqual(recipe.read_text(encoding="utf-8"), "edited by hand\n")

            wrote_again = run(args, cwd=root)
            self.assertEqual(wrote_again.returncode, 0, wrote_again.stderr)
            prov = root / "out" / "provenance.toml"
            prov.write_text("edited provenance\n", encoding="utf-8")
            drifted_prov = run([*args, "--check"], cwd=root)
            self.assertEqual(
                (drifted_prov.returncode, drifted_prov.stdout, drifted_prov.stderr),
                (1, "would update out/materialized-base.eb and out/provenance.toml\n", ""),
            )
            self.assertEqual(prov.read_text(encoding="utf-8"), "edited provenance\n")

            both = run([*args, "--dry-run", "--check"], cwd=root)
            self.assertEqual(both.returncode, 2)
            self.assertEqual(both.stdout, "")
            self.assertIn("--dry-run or --check, not both", both.stderr)

            (root / "base.eb").write_bytes(b"changed upstream\n")
            stale_base = run([*args, "--check"], cwd=root)
            self.assertEqual(stale_base.returncode, 2)
            self.assertIn("base digest", stale_base.stderr)

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

    def test_bump_and_plan_forward_global_options_after_double_dash(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "eb-stack"
            stub.write_text(
                "#!/bin/sh\n"
                'printf "%s\\n" "$@"\n',
                encoding="utf-8",
            )
            stub.chmod(0o755)
            extra = ["--help", "-h", "--config", "site.toml", "--profile", "gpu", "--project", "/proj", "--"]
            for action in ("bump", "plan"):
                with self.subTest(action=action):
                    got = run([action, "--eb-stack", str(stub), "--", *extra], text=False)
                    self.assertEqual(got.returncode, 0, got.stderr)
                    self.assertEqual(got.stderr, b"")
                    self.assertEqual(got.stdout.decode().splitlines(), ["package", action, *extra])

            # Before --, --help stays eb-local's.
            help_run = run(["bump", "--eb-stack", str(stub), "--help"])
            self.assertEqual(help_run.returncode, 0, help_run.stderr)
            self.assertIn("eb-local overlay bump", help_run.stdout)

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

    def test_materialize_reports_diagnostics_when_edits_fail(self):
        cases = [
            (
                b"name = 'demo'\n",
                '[replace]\nunknown_param = "\'--foo\'"\n',
                "eb-local: easyconfig has no parameter 'unknown_param' to replace",
            ),
            (
                b"patches = [\n    'a.patch',\n",
                '[patches]\nsite = "site.patch"\n',
                "eb-local: easyconfig patches list has no closing bracket",
            ),
            (
                b"dependencies = [('other', '1.0')]\n",
                '[dependencies.replace]\nunknown_dep = "(\'unknown_dep\', \'2.0\')"\n',
                "eb-local: easyconfig has no dependency 'unknown_dep' to replace",
            ),
            (
                b"dependencies = [('zlib', '1.0'\n",
                '[dependencies.replace]\nzlib = "(\'zlib\', \'1.2\')"\n',
                "eb-local: easyconfig dependency 'zlib' has no closing parenthesis",
            ),
        ]
        for base_bytes, section, expected_err in cases:
            with self.subTest(expected_err=expected_err), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "base.eb").write_bytes(base_bytes)
                (root / "site.overlay.toml").write_text(
                    f'overlay_version = 1\nbase_digest = "{digest_of(base_bytes)}"\n{section}',
                    encoding="utf-8",
                )
                got = run(["materialize", "--overlay", "site.overlay.toml", "--base", "base.eb"], cwd=root)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(expected_err, got.stderr)

    def test_materialize_parameter_with_trailing_spaces_keeps_valid_python(self):
        import ast

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"name = 'demo'   \nversion = '1.0'\r\n"
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest_of(content)}"\n'
                '[replace]\nname = "\'custom\'"\nversion = "\'2.0\'"\n',
                encoding="utf-8",
            )
            got = run(
                ["materialize", "--overlay", "site.overlay.toml", "--base", "base.eb", "--out-dir", "out"],
                cwd=root,
            )
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            text = (root / "out" / "materialized-base.eb").read_text(encoding="utf-8")
            ast.parse(text)
            self.assertEqual(text, "name = 'custom'\nversion = '2.0'\n")

    def test_materialize_appends_to_trailing_comma_list_as_valid_python(self):
        import ast

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"dependencies = [\n    ('zlib', '1.3'),\n]\n"
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest_of(content)}"\n'
                '[dependencies.add]\npkg = "(\'pkg\', \'1.0\')"\n',
                encoding="utf-8",
            )
            got = run(
                ["materialize", "--overlay", "site.overlay.toml", "--base", "base.eb", "--out-dir", "out"],
                cwd=root,
            )
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            text = (root / "out" / "materialized-base.eb").read_text(encoding="utf-8")
            ast.parse(text)
            self.assertNotIn(",,", text)

    def test_materialize_ignores_brackets_in_quoted_strings_and_comments(self):
        import ast

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"patches = [\n    # [note]\n    ('fix-[1].patch', 1),\n    ('a]b.patch', 1),\n]\n"
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest_of(content)}"\n'
                '[patches]\nsite = "site.patch"\n',
                encoding="utf-8",
            )
            got = run(
                ["materialize", "--overlay", "site.overlay.toml", "--base", "base.eb", "--out-dir", "out"],
                cwd=root,
            )
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            text = (root / "out" / "materialized-base.eb").read_text(encoding="utf-8")
            ast.parse(text)
            self.assertIn("('site', 'site.patch')", text)


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