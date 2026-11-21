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
                     "R_LIBS", "R_LIBS_USER", "R_LIBS_SITE", "APPTAINER_CONTAINLIBS", "SINGULARITY_CONTAINLIBS",
                     "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH", "NODE_PATH", "CARGO_BUILD_RUSTC_WRAPPER",
                     "RUSTC_WORKSPACE_WRAPPER", "R_MAKEVARS_USER", "R_MAKEVARS_SITE", "RUSTFLAGS"):
            self.env.pop(name, None)
        for key in [k for k in self.env if k.startswith("CARGO_TARGET_") and k.endswith(("_LINKER", "_RUSTFLAGS"))]:
            self.env.pop(key, None)

    def run_tool(self, args, cwd=None, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return __import__("subprocess").run(argv, env=env, cwd=cwd or self.root, capture_output=True, text=True)

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

    def test_doctor_names_host_language_paths_and_ignores_rustflags(self):
        linker = "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER"
        flags = "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS"
        keep = ("is outside the approved prefixes; "
                "a build keeps it until build.clear_foreign_prefixes is set")
        run = self.run_tool(["doctor"], **{
            "NODE_PATH": "/opt/host/node",
            "JULIA_LOAD_PATH": f"/opt/host/julia:{self.prefix}/julia",
            "JULIA_DEPOT_PATH": "/opt/host/depot",
            "CARGO_BUILD_RUSTC_WRAPPER": "/opt/host/sccache",
            "RUSTC_WORKSPACE_WRAPPER": "/opt/host/sccache",
            "R_MAKEVARS_USER": "/opt/host/Makevars",
            "R_MAKEVARS_SITE": "/opt/host/Makevars.site",
            linker: "/usr/bin/gcc",
            flags: "-C link-arg=-fuse-ld=mold",
            "RUSTFLAGS": "-C link-arg=-fuse-ld=mold",
        })
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"warn NODE_PATH entry /opt/host/node {keep}", run.stdout)
        self.assertIn(f"warn JULIA_LOAD_PATH entry /opt/host/julia {keep}", run.stdout)
        self.assertNotIn(f"warn JULIA_LOAD_PATH entry {self.prefix}/julia", run.stdout)
        self.assertIn(f"warn JULIA_DEPOT_PATH entry /opt/host/depot {keep}", run.stdout)
        self.assertIn(f"warn {linker} resolves to /usr/bin/gcc, outside the approved prefixes; "
                      "a build keeps it until build.clear_foreign_prefixes is set", run.stdout)
        self.assertIn("warn CARGO_BUILD_RUSTC_WRAPPER resolves to /opt/host/sccache", run.stdout)
        self.assertIn("warn RUSTC_WORKSPACE_WRAPPER resolves to /opt/host/sccache", run.stdout)
        self.assertIn("warn R_MAKEVARS_USER resolves to /opt/host/Makevars", run.stdout)
        self.assertIn("warn R_MAKEVARS_SITE resolves to /opt/host/Makevars.site", run.stdout)
        self.assertNotIn("RUSTFLAGS", run.stdout)
        self.assertNotIn(flags, run.stdout)

        self.env.update(
            NODE_PATH=f"/opt/host/node:{self.prefix}/node",
            RUSTFLAGS="-C link-arg=-fuse-ld=mold",
            CONTROL_PATH_NAMES=f"NODE_PATH {linker} RUSTFLAGS",
        )
        self.env[linker] = "/usr/bin/gcc"
        cleared = self.run_wrapper(["recipe.eb"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="true")
        self.assertEqual(cleared.returncode, 0, cleared.stdout + cleared.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(seen["paths"]["NODE_PATH"], f"{self.prefix}/node")
        self.assertIsNone(seen["paths"][linker])
        self.assertEqual(seen["paths"]["RUSTFLAGS"], "-C link-arg=-fuse-ld=mold")

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

    def test_approved_prefix_with_parent_component_is_refused(self):
        approved = self.root / "real-approved"
        (approved / "pkg").mkdir(parents=True)
        missing = self.root / "missing"
        missing.mkdir()
        # Keep the parent component in the spelling. With `missing` present the
        # path resolves, and that resolution would hide the parent component.
        spelled = f"{self.root}/missing/../real-approved"
        self.assertEqual(os.path.realpath(spelled), os.path.realpath(approved))
        site = self.root / "parent-prefix.toml"
        site.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "%u.%j"\n'
            'node_local_fstype = "xfs"\nshared_scratch = ["/scratch"]\n'
            f'[doctor]\napproved_prefixes = ["{spelled}"]\n',
            encoding="utf-8",
        )
        site.chmod(0o644)
        run = self.run_tool(["--config", str(site), "doctor"], PYTHONPATH=f"{approved}/pkg")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn(f"doctor.approved_prefixes path '{spelled}' has a '..' component", run.stderr)

    def test_root_equivalent_approved_prefix_is_refused(self):
        for spelled in ("/.", "/./."):
            with self.subTest(spelled=spelled):
                site = self.root / "root-prefix.toml"
                site.write_text(
                    f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "%u.%j"\n'
                    'node_local_fstype = "xfs"\nshared_scratch = ["/scratch"]\n'
                    f'[doctor]\napproved_prefixes = ["{spelled}"]\n',
                    encoding="utf-8",
                )
                site.chmod(0o644)
                run = self.run_tool(["--config", str(site), "doctor"], PYTHONPATH="/opt/host/pkg")
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertEqual(run.stdout, "")
                self.assertIn(f"doctor.approved_prefixes path '{spelled}' is the root directory", run.stderr)

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

    def test_symlinked_approved_prefix_is_kept_and_escape_symlink_is_flagged_and_scrubbed(self):
        target = self.root / "sym-target"
        (target / "lib").mkdir(parents=True)
        sym_approved = self.root / "sym-approved"
        sym_approved.symlink_to(target)
        outside = self.root / "outside-host"
        outside.mkdir()
        escape = target / "ext"
        escape.symlink_to(outside)

        site = self.root / "site.toml"
        site.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "%u.%j"\n'
            'node_local_fstype = "xfs"\nshared_scratch = ["/scratch"]\n'
            f'[doctor]\napproved_prefixes = ["{sym_approved}"]\n')
        site.chmod(0o644)

        sym_lib = f"{sym_approved}/lib"
        real_lib = f"{target}/lib"
        sym_ext = f"{sym_approved}/ext"
        py_val = f"{sym_lib}:{real_lib}:{sym_ext}"

        doctor = self.run_tool(["--config", str(site), "doctor"], PYTHONPATH=py_val)
        self.assertEqual(doctor.returncode, 0, doctor.stdout + doctor.stderr)
        self.assertNotIn(f"warn PYTHONPATH entry {sym_lib}", doctor.stdout)
        self.assertNotIn(f"warn PYTHONPATH entry {real_lib}", doctor.stdout)
        self.assertIn(f"warn PYTHONPATH entry {sym_ext} is outside the approved prefixes; "
                      "a build keeps it until build.clear_foreign_prefixes is set", doctor.stdout)

        self.env["PYTHONPATH"] = py_val
        self.env["CONTROL_PATH_NAMES"] = "PYTHONPATH"

        kept = self.run_wrapper(["--config", str(site), "recipe.eb"])
        self.assertEqual(kept.returncode, 0, kept.stdout + kept.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(seen["paths"]["PYTHONPATH"], py_val)
        (self.root / "eb.json").unlink()

        cleared = self.run_wrapper(
            ["--config", str(site), "recipe.eb"],
            EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="true",
        )
        self.assertEqual(cleared.returncode, 0, cleared.stdout + cleared.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(seen["paths"]["PYTHONPATH"], f"{sym_lib}:{real_lib}")

    def test_a_relative_or_empty_path_list_entry_is_foreign(self):
        self.prefix.mkdir(parents=True, exist_ok=True)
        locale = {"LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"}
        warn = ("warn PYTHONPATH entry {0} is outside the approved prefixes; "
                "a build keeps it until build.clear_foreign_prefixes is set")

        # doctor is started in the prefix. The build runs in its own directory,
        # so the relative entry stays foreign.
        inside = self.run_tool(["doctor"], cwd=self.prefix, PYTHONPATH="lib", **locale)
        self.assertEqual(inside.returncode, 0, inside.stdout + inside.stderr)
        self.assertIn(warn.format("lib"), inside.stdout)

        empty = self.run_tool(["doctor"], cwd=self.root, PYTHONPATH=":", **locale)
        self.assertEqual(empty.returncode, 0, empty.stdout + empty.stderr)
        self.assertIn(warn.format("''"), empty.stdout)

        climbed = self.run_tool(["doctor"], cwd=self.prefix, PYTHONPATH="lib/../lib", **locale)
        self.assertEqual(climbed.returncode, 0, climbed.stdout + climbed.stderr)
        self.assertIn(warn.format("lib/../lib"), climbed.stdout)

        self.env["PYTHONPATH"] = f"{self.prefix}/lib:"
        self.env["CONTROL_PATH_NAMES"] = "PYTHONPATH"
        self.env.update(locale)
        cleared = self.run_wrapper(["recipe.eb"], EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES="true")
        self.assertEqual(cleared.returncode, 0, cleared.stdout + cleared.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(seen["paths"]["PYTHONPATH"], f"{self.prefix}/lib")

    def test_doctor_ignores_an_empty_path_list_but_names_an_empty_entry_in_one(self):
        warn = ("warn PYTHONPATH entry '' is outside the approved prefixes; "
                "a build keeps it until build.clear_foreign_prefixes is set")
        locale = {"LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"}
        approved = f"{self.prefix}/lib"
        for value, entries in (("", 0), (":", 2), (f":{approved}", 1), (f"{approved}:", 1)):
            with self.subTest(value=value):
                run = self.run_tool(["doctor"], PYTHONPATH=value, **locale)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(run.stdout.count(warn), entries, run.stdout)
                self.assertNotIn(f"warn PYTHONPATH entry {approved}", run.stdout)


if __name__ == "__main__":
    unittest.main()
