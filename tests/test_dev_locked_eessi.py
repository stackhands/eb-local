#!/usr/bin/env python3
"""Live EESSI 2026.06 verification for `eb-local dev --locked` with llvm-compilers."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary

EESSI_INIT = Path("/cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash")


@unittest.skipUnless(
    binary.BIN and EESSI_INIT.is_file(),
    "requires Zig build and live EESSI 2026.06 on CVMFS",
)
class DevLockedLiveEessiTests(unittest.TestCase):
    def _setup_workspace(self, td):
        root = Path(td)
        prefix = root / "eessi"
        prefix.mkdir()
        src = root / "prog.c"
        src.write_text(
            "#include <fftw3.h>\n"
            "#include <stdio.h>\n"
            "int main(void) {\n"
            "    fftw_complex *p = fftw_alloc_complex(4);\n"
            "    fftw_free(p);\n"
            '    puts("llvm_locked_ok");\n'
            "    return 0;\n"
            "}\n",
            encoding="utf-8",
        )
        env = {
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "HOME": str(root),
            "USER": "ubuntu",
            "EB_LOCAL_PREFIX": str(prefix),
        }
        lock_run = subprocess.run(
            [binary.BIN, "dev", "--lock", "FFTW/3.3.10-llvm-compilers-21.1.8"],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(lock_run.returncode, 0, lock_run.stdout + lock_run.stderr)
        self.assertTrue((root / "eb-local.lock").is_file())
        return root, src, env

    def test_locked_llvm_compilers_build_gets_rpath_without_not_found(self):
        with tempfile.TemporaryDirectory(prefix="eb-local-locked-rpath-") as td:
            root, src, env = self._setup_workspace(td)
            prog = root / "prog"
            build_script = (
                f'eval "$({binary.BIN} dev --locked)"\n'
                f'clang -O2 "{src}" -lfftw3 -lm -o "{prog}"\n'
            )
            build_run = subprocess.run(
                ["bash", "--noprofile", "--norc", "-ec", build_script],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(build_run.returncode, 0, build_run.stdout + build_run.stderr)

            check_run = subprocess.run(
                [binary.BIN, "check", str(prog)],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(check_run.returncode, 0, check_run.stdout + check_run.stderr)
            self.assertNotIn("libfftw3.so.3 => not found", check_run.stdout)
            self.assertIn("libfftw3.so.3 => /cvmfs/software.eessi.io/", check_run.stdout)
            self.assertIn("[RPATH]", check_run.stdout)

            bare_run = subprocess.run(
                [str(prog)],
                env={"HOME": str(root), "PATH": "/usr/bin:/bin"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(bare_run.returncode, 0, bare_run.stdout + bare_run.stderr)
            self.assertEqual(bare_run.stdout.strip(), "llvm_locked_ok")

    def test_locked_avoids_duplicate_eessi_and_extend_reloads(self):
        with tempfile.TemporaryDirectory(prefix="eb-local-locked-reload-") as td:
            root, _, env = self._setup_workspace(td)

            fresh_run = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c", f'eval "$({binary.BIN} dev --locked)"'],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(fresh_run.returncode, 0, fresh_run.stdout + fresh_run.stderr)
            fresh_out = fresh_run.stdout + fresh_run.stderr
            self.assertEqual(
                fresh_out.count("Module for EESSI/2026.06 loaded successfully"),
                2,
                fresh_out,
            )
            self.assertEqual(
                fresh_out.count("Configuring for use of EESSI_USER_INSTALL"),
                1,
                fresh_out,
            )

            reload_script = (
                f'eval "$({binary.BIN} env)" >/dev/null 2>&1\n'
                "echo ---LOCKED-START---\n"
                f'eval "$({binary.BIN} dev --locked)"\n'
            )
            reload_run = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c", reload_script],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(reload_run.returncode, 0, reload_run.stdout + reload_run.stderr)
            after_marker = (reload_run.stdout + reload_run.stderr).split("---LOCKED-START---\n", 1)[1]
            self.assertEqual(
                after_marker.count("Module for EESSI/2026.06 loaded successfully"),
                1,
                after_marker,
            )
            self.assertEqual(
                after_marker.count("Configuring for use of EESSI_USER_INSTALL"),
                1,
                after_marker,
            )


if __name__ == "__main__":
    unittest.main()
