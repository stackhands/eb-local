#!/usr/bin/env python3
"""--json output for scriptable commands: schema_version 1 and stable keys."""
import json
from pathlib import Path
import subprocess
import unittest

import binary
from test_storage import StorageFixture

ROOT = Path(__file__).resolve().parents[1]
SCHEMAS = ROOT / "docs" / "orgmode" / "reference" / "json"


def load_schema(name):
    return json.loads((SCHEMAS / name).read_text())


def validate(doc, schema):
    """Check required keys and schema_version; types follow the JSON Schema file."""
    for key in schema.get("required", ()):
        if key not in doc:
            raise AssertionError(f"missing {key}")
    version = schema["properties"]["schema_version"]
    expect = version.get("const", version.get("enum", [1])[0])
    if doc["schema_version"] != expect:
        raise AssertionError(f"schema_version {doc['schema_version']} != {expect}")
    kind = schema["properties"].get("kind")
    if kind and "const" in kind:
        if doc.get("kind") != kind["const"]:
            raise AssertionError(f"kind {doc.get('kind')}")


@unittest.skipUnless(binary.BIN, "--json is a Zig build feature")
class JsonCli(StorageFixture):
    def run_json(self, args, allow_fail=False, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        if not allow_fail:
            self.assertEqual(run.returncode, 0, run.stderr)
        line = run.stdout.strip()
        self.assertNotIn("\n", line, "one line of JSON")
        return json.loads(line)

    def test_list_json_matches_schema(self):
        tree = self.prefix / "versions/2026.06/software/linux/x86_64/amd/zen2"
        (tree / "software/demo/1.0").mkdir(parents=True)
        (tree / "modules/all/demo/1.0.lua").parent.mkdir(parents=True)
        (tree / "modules/all/demo/1.0.lua").write_text("-- m\n")
        (tree / "software/other/2.0").mkdir(parents=True)
        (tree / "modules/all/other/2.0.lua").parent.mkdir(parents=True)
        (tree / "modules/all/other/2.0.lua").write_text("-- m\n")

        # Default text output in raw bytes stays unchanged.
        argv_txt, env_txt = binary.command(self.script, ["list"], dict(self.env, SLURM_JOB_ID=""))
        raw_txt = subprocess.run(argv_txt, env=env_txt, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(raw_txt.returncode, 0, raw_txt.stderr)
        self.assertEqual(raw_txt.stderr, b"")
        self.assertIn(b"2 module(s) for 1 CPU target(s)", raw_txt.stdout)
        self.assertIn(b"demo/1.0", raw_txt.stdout)
        self.assertIn(b"other/2.0", raw_txt.stdout)

        doc = self.run_json(["list", "--json"], SLURM_JOB_ID="")
        validate(doc, load_schema("list.schema.json"))
        self.assertEqual(doc["kind"], "list")
        self.assertEqual(doc["prefix"], str(self.prefix))
        self.assertEqual(doc["filters"], [])
        self.assertFalse(doc["empty"])
        self.assertEqual([m["name"] for m in doc["modules"]], ["demo/1.0", "other/2.0"])

        filtered = self.run_json(["list", "--json", "demo"], SLURM_JOB_ID="")
        validate(filtered, load_schema("list.schema.json"))
        self.assertEqual(filtered["filters"], ["demo"])
        self.assertFalse(filtered["empty"])
        self.assertEqual([m["name"] for m in filtered["modules"]], ["demo/1.0"])

    def test_doctor_json_matches_schema(self):
        doc = self.run_json(["doctor", "--json"], allow_fail=True, SLURM_JOB_ID="")
        validate(doc, load_schema("doctor.schema.json"))
        self.assertIn("lines", doc)
        self.assertIn("summary", doc)

    def test_config_json_matches_schema(self):
        doc = self.run_json(["config", "--json"], SLURM_JOB_ID="")
        validate(doc, load_schema("config.schema.json"))
        self.assertGreaterEqual(len(doc["settings"]), 1)

    def test_profiles_json_matches_schema(self):
        doc = self.run_json(["profiles", "--json"], SLURM_JOB_ID="")
        validate(doc, load_schema("profiles.schema.json"))

    def test_site_list_json_matches_schema(self):
        doc = self.run_json(["site", "list", "--json"], SLURM_JOB_ID="")
        validate(doc, load_schema("site_list.schema.json"))
        self.assertTrue(any(t["name"] == "slurm" for t in doc["templates"]))

    def test_site_list_without_json_is_byte_identical(self):
        argv, env = binary.command(
            self.script, ["site", "list"], dict(self.env, SLURM_JOB_ID="")
        )
        run = subprocess.run(
            argv, env=env, cwd=self.root, capture_output=True, text=False
        )
        self.assertEqual(run.returncode, 0, run.stderr.decode())
        expected = (ROOT / "tests/fixtures/site-list-without-json.txt").read_bytes()
        self.assertEqual(run.stdout, expected)

    def test_clean_without_json_is_byte_identical(self):
        import os
        import time

        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True)
        old = logs / "easybuild-0.log"
        old.write_text("log\n")
        t = time.time() - 40 * 86400
        os.utime(old, (t, t))

        argv, env = binary.command(
            self.script, ["clean", "--dry-run"], dict(self.env, SLURM_JOB_ID="")
        )
        dry = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        expected_dry = (
            f"  {old}\n"
            "eb-local: dry run, nothing removed (1 item(s), 0 workspace(s))\n"
        ).encode()
        self.assertEqual((dry.returncode, dry.stdout, dry.stderr), (0, expected_dry, b""))

        argv, env = binary.command(
            self.script, ["clean", "--delete"], dict(self.env, SLURM_JOB_ID="")
        )
        deleted = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        expected_del = (
            f"  {old}\n"
            "eb-local: deleted 1 item(s)\n"
        ).encode()
        self.assertEqual((deleted.returncode, deleted.stdout, deleted.stderr), (0, expected_del, b""))

        argv, env = binary.command(
            self.script, ["clean"], dict(self.env, SLURM_JOB_ID="")
        )
        empty = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        expected_empty = f"eb-local: nothing to clean in {self.prefix}\n".encode()
        self.assertEqual((empty.returncode, empty.stdout, empty.stderr), (0, expected_empty, b""))

    def test_clean_json_matches_schema(self):
        import os
        import time

        schema = load_schema("clean.schema.json")
        nothing = self.run_json(["clean", "--json"], SLURM_JOB_ID="")
        validate(nothing, schema)
        self.assertEqual(nothing["action"], "nothing")
        self.assertEqual(nothing["items"], [])
        self.assertEqual(nothing["workspaces"], [])

        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True)
        old_file = logs / "easybuild-0.log"
        old_file.write_text("log\n")
        old_dir = logs / "reprod_1"
        old_dir.mkdir()
        (old_dir / "easybuild.log").write_text("inner\n")
        t = time.time() - 40 * 86400
        os.utime(old_file, (t, t))
        os.utime(old_dir / "easybuild.log", (t, t))
        os.utime(old_dir, (t, t))

        dry = self.run_json(["clean", "--dry-run", "--json"], SLURM_JOB_ID="")
        validate(dry, schema)
        self.assertTrue(dry["dry_run"])
        self.assertEqual(dry["action"], "dry-run")
        self.assertEqual(dry["removed_items"], 0)
        self.assertEqual(len(dry["items"]), 2)
        self.assertTrue(old_file.exists() and old_dir.exists())

        refused = self.run_json(
            ["clean", "--json"],
            allow_fail=True,
            SLURM_JOB_ID="",
            EB_LOCAL_CLEAN_TRASH="none",
        )
        validate(refused, schema)
        self.assertEqual(refused["action"], "refused")
        self.assertEqual(refused["removed_items"], 0)
        self.assertTrue(old_file.exists())

        deleted = self.run_json(["clean", "--delete", "--json"], SLURM_JOB_ID="")
        validate(deleted, schema)
        self.assertEqual(deleted["action"], "deleted")
        self.assertEqual(deleted["removed_items"], 2)
        self.assertFalse(old_file.exists() or old_dir.exists())

        ws = self.job / "eb-local.AbCdEf12"
        ws.mkdir()
        ws_doc = self.run_json(["clean", "--workspaces", "--no-logs", "--json"])
        validate(ws_doc, schema)
        self.assertEqual(ws_doc["action"], "workspaces-only")
        self.assertEqual(ws_doc["workspaces"], [str(ws)])
        self.assertEqual(ws_doc["removed_workspaces"], 1)
        self.assertFalse(ws.exists())

        rtrash_bin = self.root / "rtrash-bin"
        rtrash_bin.mkdir()
        trashed_log = self.root / "trashed"
        rtrash = rtrash_bin / "rtrash"
        rtrash.write_text(
            "#!/bin/sh\n"
            'shift; shift\n'
            'for p in "$@"; do printf "%s\\n" "$p" >> "' + str(trashed_log) + '"; rm -rf -- "$p"; done\n'
        )
        rtrash.chmod(0o755)
        trashed_file = logs / "easybuild-1.log"
        trashed_file.parent.mkdir(parents=True, exist_ok=True)
        trashed_file.write_text("trash me\n")
        os.utime(trashed_file, (t, t))
        trashed = self.run_json(
            ["clean", "--json"],
            SLURM_JOB_ID="",
            PATH=f"{rtrash_bin}:{os.environ['PATH']}",
        )
        validate(trashed, schema)
        self.assertEqual(trashed["action"], "trashed")
        self.assertEqual(trashed["removed_items"], 1)
        self.assertEqual(trashed_log.read_text().splitlines(), [str(trashed_file)])

    def test_modulerc_json_matches_schema(self):
        schema = load_schema("modulerc.schema.json")
        tree = self.root / "modulerc-tree"
        control = tree / ".modulerc.lua"
        base_args = [
            "modulerc",
            "--module-tree",
            str(tree),
            "--default",
            "Example/2.0",
            "--alias",
            "Example/latest=Example/2.0",
            "--hide",
            "Example/1.0",
        ]

        drift = self.run_json([*base_args, "--check", "--json"], allow_fail=True, SLURM_JOB_ID="")
        argv, env = binary.command(self.script, [*base_args, "--check", "--json"], dict(self.env, SLURM_JOB_ID=""))
        drift_proc = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual((drift_proc.returncode, drift_proc.stderr), (1, ""))
        validate(drift, schema)
        self.assertEqual(set(drift.keys()), set(schema["properties"].keys()))
        self.assertEqual(drift["mode"], "check")
        self.assertTrue(drift["changed"])
        self.assertIsNone(drift["content"])
        self.assertEqual(drift["defaults"], ["Example/2.0"])
        self.assertEqual(drift["aliases"], [{"name": "Example/latest", "target": "Example/2.0"}])
        self.assertEqual(drift["hidden"], ["Example/1.0"])
        self.assertFalse(tree.exists())

        dry = self.run_json([*base_args, "--dry-run", "--json"], SLURM_JOB_ID="")
        validate(dry, schema)
        self.assertEqual(set(dry.keys()), set(schema["properties"].keys()))
        self.assertEqual(dry["mode"], "dry-run")
        self.assertTrue(dry["changed"])
        self.assertIn('module_version("Example/2.0", "default")', dry["content"])
        self.assertFalse(tree.exists())

        wrote = self.run_json([*base_args, "--json"], SLURM_JOB_ID="")
        validate(wrote, schema)
        self.assertEqual(set(wrote.keys()), set(schema["properties"].keys()))
        self.assertEqual(wrote["mode"], "write")
        self.assertTrue(wrote["changed"])
        self.assertIsNone(wrote["content"])
        self.assertEqual(wrote["file"], str(control))
        self.assertTrue(control.is_file())

        clean = self.run_json([*base_args, "--check", "--json"], SLURM_JOB_ID="")
        validate(clean, schema)
        self.assertEqual(clean["mode"], "check")
        self.assertFalse(clean["changed"])
        self.assertIsNone(clean["content"])


if __name__ == "__main__":
    unittest.main()