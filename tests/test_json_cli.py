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
        (tree / "modules/all/demo/1.0.lua").parent.mkdir(parents=True)
        (tree / "modules/all/demo/1.0.lua").write_text("-- m\n")
        doc = self.run_json(["list", "--json"], SLURM_JOB_ID="")
        validate(doc, load_schema("list.schema.json"))
        self.assertEqual(doc["kind"], "list")
        self.assertEqual(doc["prefix"], str(self.prefix))

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


if __name__ == "__main__":
    unittest.main()