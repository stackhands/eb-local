#!/usr/bin/env python3
"""The release SBOM (tools/sbom.py) names the binary by digest and every
Zig dependency build.zig.zon pins, and is the same for the same inputs."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "sbom.py"


class Sbom(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.zon = (ROOT / "build.zig.zon").read_text()
        self.version = [l.split('"')[1] for l in self.zon.splitlines() if l.strip().startswith(".version")][0]
        self.binary = self.root / f"eb-local-{self.version}-x86_64-linux-musl"
        self.binary.write_bytes(b"\x7fELF not really\n")

    def tearDown(self):
        self.tmp.cleanup()

    def generate(self, zon=None):
        path = ROOT / "build.zig.zon"
        if zon is not None:
            path = self.root / "build.zig.zon"
            path.write_text(zon)
        return subprocess.run([sys.executable, "-I", str(TOOL), "--binary", str(self.binary), "--zon", str(path),
                               "--zig", "0.17.1", "--commit", "abc1234"], capture_output=True, text=True)

    def test_names_the_binary_and_every_pinned_dependency(self):
        run = self.generate()
        self.assertEqual(run.returncode, 0, run.stderr)
        bom = json.loads(run.stdout)
        self.assertEqual((bom["bomFormat"], bom["specVersion"]), ("CycloneDX", "1.6"))
        me = bom["metadata"]["component"]
        self.assertEqual(me["version"], self.version)
        self.assertEqual(me["hashes"], [{"alg": "SHA-256", "content": hashlib.sha256(self.binary.read_bytes()).hexdigest()}])
        self.assertIn({"name": "target", "value": "x86_64-linux-musl"}, me["properties"])
        names = {c["name"] for c in bom["components"]}
        self.assertIn("musl", names)
        common = next(c for c in bom["components"] if c["name"] == "zig-common")
        self.assertRegex(common["purl"], r"^pkg:github/stackhands/zig-common@(?:v\d|[0-9a-f]{40}$)")
        self.assertIn(common["properties"][0]["value"], self.zon)
        refs = {c["bom-ref"] for c in bom["components"]}
        self.assertEqual(set(bom["dependencies"][0]["dependsOn"]), refs)

    def test_the_same_inputs_give_the_same_sbom(self):
        self.assertEqual(self.generate().stdout, self.generate().stdout)

    def test_a_dependency_without_a_package_url_is_an_error(self):
        zon = self.zon.replace("git+https://github.com/stackhands/zig-common", "https://example.org/zig-common.tar.gz")
        run = self.generate(zon)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("cannot name", run.stderr)

    def test_handles_reordered_fields_and_two_space_indentation(self):
        zon = (
            '.{\n'
            '  .name = .eb_local,\n'
            f'  .version = "{self.version}",\n'
            '  .dependencies = .{\n'
            '    .zig_common = .{\n'
            '      .hash = "zig_common-0.10.0-abc",\n'
            '      .url = "git+https://github.com/stackhands/zig-common#v0.10.0",\n'
            '      .lazy = true,\n'
            '    },\n'
            '  },\n'
            '}\n'
        )
        run = self.generate(zon)
        self.assertEqual(run.returncode, 0, run.stderr)
        bom = json.loads(run.stdout)
        names = {c["name"] for c in bom["components"]}
        self.assertIn("zig-common", names)

    def test_ignores_commented_out_dependencies_in_zon(self):
        zon = (
            '.{\n'
            '  .name = .eb_local,\n'
            f'  .version = "{self.version}",\n'
            '  .dependencies = .{\n'
            '    // .old_dep = .{ .url = "https://example.org/old.tar.gz", .hash = "deadbeef" },\n'
            '    .zig_common = .{\n'
            '      .url = "git+https://github.com/stackhands/zig-common#v0.10.0",\n'
            '      .hash = "zig_common-0.10.0-abc",\n'
            '    },\n'
            '  },\n'
            '}\n'
        )
        run = self.generate(zon)
        self.assertEqual(run.returncode, 0, run.stderr)
        bom = json.loads(run.stdout)
        names = {c["name"] for c in bom["components"]}
        self.assertEqual(names, {"zig-common", "musl"})

    def test_commit_sha_pin_sets_exact_purl_and_version(self):
        sha = "8173ca239722581bb738adb9daa4ef09c4b6cdb0"
        zon = (
            '.{\n'
            '  .name = .eb_local,\n'
            f'  .version = "{self.version}",\n'
            '  .dependencies = .{\n'
            '    .zig_common = .{\n'
            f'      .url = "git+https://github.com/stackhands/zig-common#{sha}",\n'
            '      .hash = "zig_common-0.12.0-abc",\n'
            '    },\n'
            '  },\n'
            '}\n'
        )
        run = self.generate(zon)
        self.assertEqual(run.returncode, 0, run.stderr)
        bom = json.loads(run.stdout)
        common = next(c for c in bom["components"] if c["name"] == "zig-common")
        self.assertEqual(common["version"], sha)
        self.assertEqual(common["purl"], f"pkg:github/stackhands/zig-common@{sha}")


if __name__ == "__main__":
    unittest.main()
