#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local dev` module validation and warnings."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "dev is a feature of the Zig build")
class DevCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-dev-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.site = self.root / "site.toml"
        self.site.write_text('[storage]\nnode_local_root = "/local"\n', encoding="utf-8")
        self.site.chmod(0o600)

    def run_dev(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": str(self.site),
            "EB_LOCAL_PREFIX": str(self.prefix),
            "EESSI_VERSION": "2026.06",
            "EESSI_SOFTWARE_SUBDIR": "x86_64/generic",
            "EESSI_ACCELERATOR_TARGET": "",
        }
        env.pop("LD_LIBRARY_PATH", None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, "dev", *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_invalid_module_names_exit_two(self):
        for bad in ("bad;module", "../escape/1.0", "Foo//1.0"):
            with self.subTest(bad=bad):
                got = self.run_dev([bad])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("is not a module name", got.stderr)

    def test_json_is_the_change_the_dev_lines_make(self):
        got = self.run_dev(["--json"])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout.count("\n"), 1, got.stdout)
        change = json.loads(got.stdout)
        self.assertEqual(change["kind"], "dev")
        values = {var["name"]: var["value"] for var in change["set"]}
        self.assertIn("EB_LOCAL_DEV_PREFIX", values)
        self.assertTrue(values["EB_LOCAL_DEV_PREFIX"].startswith(str(self.prefix) + "/dev/"), values)
        self.assertNotIn("module load", got.stdout)
    def test_envrc_writes_the_dev_line_and_updates_only_its_own_block(self):
        envrc = self.root / ".envrc"
        got = self.run_dev(["--envrc", "FFTW/3.3.10-GCC-15.2.0"])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("direnv allow", got.stderr)
        first = envrc.read_text()
        lines = first.splitlines()
        self.assertTrue(lines[0].startswith("# >>> eb-local dev >>>"), first)
        self.assertEqual(lines[-1], "# <<< eb-local dev <<<")
        self.assertEqual(len(lines), 3)
        # the program is named by its own path, and the line replays this dev
        self.assertTrue(lines[1].startswith('eval "$(' + binary.BIN + " "), lines[1])
        self.assertTrue(lines[1].endswith(' dev FFTW/3.3.10-GCC-15.2.0)"'), lines[1])

        # the user's own lines around the block survive a rewrite with other modules
        envrc.write_text("export MINE=1\n" + first + "layout python\n")
        again = self.run_dev(["--envrc", "--buildenv", "buildenv/custom", "HDF5/1.14.6-gompi-2026.1"])
        self.assertEqual(again.returncode, 0, again.stderr)
        second = envrc.read_text().splitlines()
        self.assertEqual(second[0], "export MINE=1")
        self.assertEqual(second[-1], "layout python")
        self.assertEqual(len(second), 5)
        self.assertIn("--buildenv buildenv/custom", second[2])
        self.assertIn("HDF5/1.14.6-gompi-2026.1", second[2])
        self.assertNotIn("FFTW", "\n".join(second))

        # a file without the block gets it appended, after a newline
        envrc.write_text("export MINE=1")
        self.assertEqual(self.run_dev(["--envrc"]).returncode, 0)
        third = envrc.read_text().splitlines()
        self.assertEqual(third[0], "export MINE=1")
        self.assertTrue(third[1].startswith("# >>> eb-local dev >>>"))
        self.assertEqual(len(third), 4)

        # a begin line without its end line is refused and the file is left alone
        broken = "# >>> eb-local dev >>> by hand\nexport MINE=1\n"
        envrc.write_text(broken)
        refused = self.run_dev(["--envrc"])
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("without", refused.stderr)
        self.assertEqual(envrc.read_text(), broken)

    def test_the_envrc_block_is_valid_bash_that_runs_the_dev_lines(self):
        self.assertEqual(self.run_dev(["--envrc"]).returncode, 0)
        # bash, as direnv runs it: the block evaluates this program's dev lines
        run = subprocess.run(
            ["bash", "-c", 'source ./.envrc >/dev/null 2>&1; printf %s "${EB_LOCAL_DEV_PREFIX-}"'],
            cwd=self.root,
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root), "EB_LOCAL_CONFIG": str(self.site),
                 "EB_LOCAL_PREFIX": str(self.prefix), "EESSI_VERSION": "2026.06",
                 "EESSI_SOFTWARE_SUBDIR": "x86_64/generic", "EESSI_ACCELERATOR_TARGET": ""},
            capture_output=True, text=True,
        )
        self.assertTrue(run.stdout.startswith(str(self.prefix) + "/dev/"), run.stdout + run.stderr)
    def test_pure_purges_modules_and_loader_variables_before_the_stack_loads(self):
        plain = self.run_dev(["FFTW/3.3.10-GCC-15.2.0"], LD_LIBRARY_PATH="/host/lib")
        pure = self.run_dev(["--pure", "FFTW/3.3.10-GCC-15.2.0"], LD_LIBRARY_PATH="/host/lib")
        self.assertEqual(pure.returncode, 0, pure.stderr)
        purge = "module purge >/dev/null 2>&1 || true\nunset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT\n"
        self.assertNotIn("module purge", plain.stdout)
        self.assertEqual(pure.stdout.count(purge), 1)
        # the rest of the lines is what dev prints without it
        self.assertEqual(pure.stdout.replace(purge, ""), plain.stdout)
        # after a module command exists, before anything is loaded
        self.assertLess(pure.stdout.index("type module"), pure.stdout.index(purge))
        self.assertLess(pure.stdout.index(purge), pure.stdout.index("module load"))
        # the variable is unset by the lines, so there is nothing to warn about
        self.assertIn("LD_LIBRARY_PATH is set", plain.stderr)
        self.assertNotIn("LD_LIBRARY_PATH is set", pure.stderr)

    LOADED = "EESSI/2026.06:GCCcore/15.2.0:FFTW/3.3.10-GCC-15.2.0:buildenv/default-GCC-15.2.0"
    RESOLVED = {"LOADEDMODULES": LOADED, "EESSI_SOFTWARE_SUBDIR": "x86_64/amd/zen4", "EESSI_VERSION": "2026.06"}

    def test_lock_records_what_the_dev_lines_loaded(self):
        lock = self.root / "eb-local.lock"
        got = self.run_dev(["--lock", "FFTW/3.3.10-GCC-15.2.0"], **self.RESOLVED)
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("wrote eb-local.lock: 4 modules for x86_64/amd/zen4", got.stderr)
        text = lock.read_text()
        self.assertEqual(text.count("\n"), 1)
        record = json.loads(text)
        self.assertEqual(record["kind"], "dev-lock")
        self.assertEqual(record["schema_version"], 1)
        self.assertEqual(record["cpu_target"], "x86_64/amd/zen4")
        self.assertEqual(record["eessi_version"], "2026.06")
        self.assertEqual(record["accelerator_target"], "")
        self.assertEqual(record["modules"], self.LOADED.split(":"))
        self.assertTrue(record["stack"])

        # a second lock replaces the first
        again = self.run_dev(["--lock"], **dict(self.RESOLVED, LOADEDMODULES="EESSI/2026.06"))
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(json.loads(lock.read_text())["modules"], ["EESSI/2026.06"])

        # nothing loaded, nothing to lock: the file is left as it is
        before = lock.read_text()
        empty = self.run_dev(["--lock"], EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(empty.returncode, 1)
        self.assertIn("nothing to lock", empty.stderr)
        self.assertEqual(lock.read_text(), before)

    def test_locked_loads_exactly_the_lock_and_checks_the_cpu_target(self):
        lock = self.root / "eb-local.lock"
        missing = self.run_dev(["--locked"])
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("there is no eb-local.lock here", missing.stderr)

        self.assertEqual(self.run_dev(["--lock"], **self.RESOLVED).returncode, 0)
        got = self.run_dev(["--locked"])
        self.assertEqual(got.returncode, 0, got.stderr)
        load = "module load " + " ".join(self.LOADED.split(":")) + "\n"
        self.assertEqual(got.stdout.count(load), 1)
        self.assertEqual(got.stdout.count("module load"), 2)  # the stack, then the lock
        # purged first, and the lock's modules only on its own CPU target
        self.assertLess(got.stdout.index("module purge"), got.stdout.index(load))
        self.assertIn('if [ "${EESSI_SOFTWARE_SUBDIR-}" != x86_64/amd/zen4 ]; then', got.stdout)
        self.assertIn("export EB_LOCAL_DEV_PREFIX=", got.stdout)

        def run_lines(subdir):
            return subprocess.run(
                ["bash", "-c", got.stdout + 'printf "%s" "${EB_LOCAL_DEV_PREFIX-unset}"'],
                env={"PATH": "/usr/bin:/bin", "HOME": str(self.root), "EESSI_SOFTWARE_SUBDIR": subdir,
                     "EESSI_VERSION": "2026.06"},
                capture_output=True, text=True,
            )

        other = run_lines("x86_64/intel/icelake")
        self.assertIn("was written for the CPU target", other.stderr)
        self.assertIn("this shell has x86_64/intel/icelake", other.stderr)
        self.assertEqual(other.stdout, "unset")
        same = run_lines("x86_64/amd/zen4")
        self.assertNotIn("was written for the CPU target", same.stderr)
        self.assertTrue(same.stdout.endswith("/dev/2026.06/x86_64/amd/zen4"), same.stdout)

        # modules come from the lock, not from the line
        named = self.run_dev(["--locked", "FFTW/3.3.10-GCC-15.2.0"])
        self.assertNotEqual(named.returncode, 0)
        self.assertIn("name none on the line", named.stderr)

        # a lock of another stack, a lock that is not one, and a hostile module name are refused
        record = json.loads(lock.read_text())
        for change, message in (
            ({"stack": "EESSI/2099.01"}, "was written with the stack EESSI/2099.01"),
            ({"kind": "something-else"}, "is not a dev lock"),
            ({"modules": ["ok/1.0", "bad;rm -rf /"]}, "is not a module name"),
            ({"cpu_target": "x86_64/$(id)"}, "names no usable CPU target"),
            ({"modules": []}, "lists no modules"),
        ):
            with self.subTest(change=change):
                lock.write_text(json.dumps(dict(record, **change)) + "\n")
                refused = self.run_dev(["--locked"])
                self.assertNotEqual(refused.returncode, 0)
                self.assertEqual(refused.stdout, "")
                self.assertIn(message, refused.stderr)
        lock.write_text("not json\n")
        self.assertIn("is not a lock eb-local wrote", self.run_dev(["--locked"]).stderr)

    def test_names_the_host_ca_bundle_without_replacing_one_the_shell_set(self):
        got = self.run_dev([])
        self.assertEqual(got.returncode, 0, got.stderr)
        start = got.stdout.index("if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then")
        block = got.stdout[start:got.stdout.index("\nfi\n", start) + 4]
        self.assertLess(got.stdout.rindex("module load"), start)

        def after(present, **given):
            # The block with its three host paths under a scratch root.
            with tempfile.TemporaryDirectory() as root:
                for rel in present:
                    path = Path(root) / rel
                    path.parent.mkdir(parents=True)
                    path.write_text("")
                script = block.replace("/etc/", root + "/etc/")
                script += 'printf "%s|%s" "${SSL_CERT_FILE-}" "${CARGO_HTTP_CAINFO-}"\n'
                env = {"PATH": os.environ["PATH"], **given}
                run = subprocess.run(["bash", "-euc", script], env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)
                return run.stdout.replace(root, "")

        rhel = "etc/pki/tls/certs/ca-bundle.crt"
        self.assertEqual(after([rhel]), f"/{rhel}|/{rhel}")
        self.assertEqual(after([rhel], SSL_CERT_FILE="/mine.pem"), f"/mine.pem|/{rhel}")
        self.assertEqual(after([rhel], CARGO_HTTP_CAINFO="/mine.pem"), f"/{rhel}|/mine.pem")
        self.assertEqual(after([rhel, "etc/ssl/certs/ca-certificates.crt"]), "|")
        self.assertEqual(after(["etc/ssl/ca-bundle.pem"]), "/etc/ssl/ca-bundle.pem|/etc/ssl/ca-bundle.pem")
        self.assertEqual(after([]), "|")

    def test_deduplicates_modules_and_warns_for_gcc_buildenv_with_lfoss_module(self):
        got = self.run_dev(
            [
                "--buildenv",
                "buildenv/default-foss-2026.1",
                "ScaLAPACK/2.2.2-lfoss-2026.1",
                "ScaLAPACK/2.2.2-lfoss-2026.1",
                "buildenv/default-foss-2026.1",
            ],
            LD_LIBRARY_PATH="/host/lib",
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("belongs to the lfoss toolchain", got.stderr)
        self.assertIn("LD_LIBRARY_PATH is set", got.stderr)
        self.assertIn("module load ScaLAPACK/2.2.2-lfoss-2026.1\n", got.stdout)
        self.assertEqual(got.stdout.count("ScaLAPACK/2.2.2-lfoss-2026.1"), 1)
        self.assertIn("module load buildenv/default-foss-2026.1\n", got.stdout)
        self.assertIn("export EB_LOCAL_DEV_PREFIX=", got.stdout)

    def test_strict_prepends_cvmfs_init_check_before_module_loads(self):
        got = self.run_dev(["--strict", "--buildenv", "buildenv/custom", "Demo/1.0"])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("mount EESSI with CVMFS", got.stdout)
        self.assertLess(got.stdout.index("mount EESSI with CVMFS"), got.stdout.index("module load Demo/1.0"))

    def test_strict_dev_exits_two_when_eessi_init_path_is_a_directory(self):
        repo = self.root / "repo"
        init_dir = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_dir.mkdir(parents=True)
        got = self.run_dev(["--strict"], EESSI_CVMFS_REPO=str(repo))
        self.assertEqual(got.returncode, 0, got.stderr)
        proc = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", got.stdout],
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.root),
                "EESSI_CVMFS_REPO": str(repo),
                "LMOD_PKG": str(self.root / "no-lmod"),
            },
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("CVMFS", proc.stderr)


if __name__ == "__main__":
    unittest.main()
