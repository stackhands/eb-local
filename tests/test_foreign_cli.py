#!/usr/bin/env python3
"""Foreign prefixes, timezone and injected host libraries in doctor, and the opt-in clear."""
import json
import os
from pathlib import Path
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(binary.BIN, "foreign-prefix checks are part of the Zig build")
class ForeignPrefixes(StorageFixture):
    def setUp(self):
        super().setUp()
        self.env["LMOD_CMD"] = "/usr/share/lmod/lmod/libexec/lmod"
        modules = self.root / "init" / "modules"
        (modules / "EESSI").mkdir(parents=True)
        (modules / "EESSI" / "2026.06.lua").write_text("-- module\n")
        self.env["MODULEPATH"] = str(modules)
        for name in ("PERL5LIB", "PYTHONPATH", "CMAKE_PREFIX_PATH", "PKG_CONFIG_PATH", "CC", "CXX",
                     "R_LIBS", "R_LIBS_USER", "R_LIBS_SITE", "APPTAINER_CONTAINLIBS", "SINGULARITY_CONTAINLIBS"):
            self.env.pop(name, None)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return __import__("subprocess").run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_doctor_names_a_foreign_entry_and_keeps_an_approved_one(self):
        run = self.run_tool(["doctor"], PERL5LIB=f"/opt/host/perl5:{self.prefix}/lib",
                            CC="/usr/bin/gcc", CXX=f"{self.prefix}/bin/g++")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn PERL5LIB entry /opt/host/perl5 is outside the approved prefixes; "
                      "a build keeps it until build.clear_foreign_prefixes is set", run.stdout)
        self.assertNotIn(f"warn PERL5LIB entry {self.prefix}/lib", run.stdout)
        self.assertIn("warn CC resolves to /usr/bin/gcc, outside the approved prefixes; "
                      "a build keeps it until build.clear_foreign_prefixes is set", run.stdout)
        self.assertNotIn("warn CXX resolves", run.stdout)
        self.assertRegex(run.stdout, r"info timezone target \S+")
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))

    def test_clearing_is_off_until_asked_and_then_drops_only_foreign_entries(self):
        explained = self.run_tool(["--explain", "recipe.eb"])
        self.assertEqual(explained.returncode, 0, explained.stderr)
        self.assertNotIn("clear_foreign_prefixes", explained.stdout)
        self.env["PERL5LIB"] = f"/opt/host/perl5:{self.prefix}/lib"
        self.env["CC"] = "/usr/bin/gcc"
        self.env["CONTROL_PATH_NAMES"] = "PERL5LIB CC"
        kept = self.run_wrapper(["recipe.eb"])
        self.assertEqual(kept.returncode, 0, kept.stdout + kept.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(seen["paths"]["PERL5LIB"], f"/opt/host/perl5:{self.prefix}/lib")
        self.assertEqual(seen["paths"]["CC"], "/usr/bin/gcc")
        (self.root / "eb.json").unlink()

        doctor = self.run_tool(["doctor"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="true")
        self.assertIn("a build drops it because build.clear_foreign_prefixes is set", doctor.stdout)
        cleared = self.run_wrapper(["recipe.eb"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="true")
        self.assertEqual(cleared.returncode, 0, cleared.stdout + cleared.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(seen["paths"]["PERL5LIB"], f"{self.prefix}/lib")
        self.assertIsNone(seen["paths"]["CC"])
        self.assertNotIn("OMPI_MCA_pml", json.dumps(seen))

        again = self.run_tool(["--explain", "recipe.eb"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="1")
        self.assertIn("because build.clear_foreign_prefixes is set", again.stdout)

    def test_an_explicit_false_is_byte_identical_to_the_default_build(self):
        self.env["PERL5LIB"] = f"/opt/host/perl5:{self.prefix}/lib"
        self.env["CC"] = "/usr/bin/gcc"
        self.env["CONTROL_PATH_NAMES"] = "PERL5LIB CC"

        default_explain = self.run_tool(["--explain", "recipe.eb"])
        disabled_explain = self.run_tool(
            ["--explain", "recipe.eb"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="false")
        self.assertEqual(disabled_explain.returncode, default_explain.returncode)
        self.assertEqual(disabled_explain.stdout.encode(), default_explain.stdout.encode())
        self.assertEqual(disabled_explain.stderr.encode(), default_explain.stderr.encode())

        default = self.run_wrapper(["recipe.eb"])
        self.assertEqual(default.returncode, 0, default.stdout + default.stderr)
        default_capture = (self.root / "eb.json").read_bytes()
        (self.root / "eb.json").unlink()

        disabled = self.run_wrapper(
            ["recipe.eb"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="false")
        self.assertEqual(disabled.returncode, 0, disabled.stdout + disabled.stderr)
        self.assertEqual((self.root / "eb.json").read_bytes(), default_capture)

    def test_an_injected_library_directory_is_reported(self):
        run = self.run_tool(["doctor"], APPTAINER_CONTAINLIBS="/opt/host/cuda/libcuda.so")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn runtime-injected host library directory /opt/host/cuda", run.stdout)

    def test_a_site_prefix_approves_an_entry_and_a_user_file_cannot(self):
        site = self.root / "site.toml"
        site.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "%u.%j"\n'
            'node_local_fstype = "xfs"\nshared_scratch = ["/scratch"]\n'
            '[doctor]\napproved_prefixes = ["/opt/host"]\n')
        site.chmod(0o644)
        run = self.run_tool(["--config", str(site), "doctor"], PERL5LIB="/opt/host/perl5")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("warn PERL5LIB", run.stdout)
        home = self.root / "home"
        conf = home / ".config" / "eb-local"
        conf.mkdir(parents=True)
        (conf / "config.toml").write_text('[doctor]\napproved_prefixes = ["/opt/host"]\n')
        (conf / "config.toml").chmod(0o600)
        refused = self.run_tool(["doctor"], HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"))
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("doctor.approved_prefixes is a site setting", refused.stderr)

    def test_xdg_cache_home_wrapper_is_approved_without_home(self):
        cache = self.root / "xdg-cache"
        wrapper = cache / "eb-local" / "rpath-0123456789abcdef" / "gcc"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text("#!/bin/sh\nexit 0\n")
        wrapper.chmod(0o755)
        self.env.pop("HOME", None)
        run = self.run_tool(
            ["doctor"],
            XDG_CACHE_HOME=str(cache),
            CC=str(wrapper),
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("warn CC resolves", run.stdout)


if __name__ == "__main__":
    unittest.main()
