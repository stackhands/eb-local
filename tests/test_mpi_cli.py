#!/usr/bin/env python3
"""doctor --mpi: fabric tools, Slurm binding, and a two-rank hello that a build never inherits."""
import json
import unittest

import binary
from test_storage import StorageFixture


def script(path, text):
    path.write_text(text)
    path.chmod(0o755)


HELLO = """#!/bin/sh
echo "hello rank=0 size=2 cpu=0 cpus=2"
echo "hello rank=1 size=2 cpu=1 cpus=2"
"""

SHARED = """#!/bin/sh
echo "hello rank=0 size=2 cpu=0 cpus=2"
echo "hello rank=1 size=2 cpu=0 cpus=2"
"""


@unittest.skipUnless(binary.ZIG, "MPI checks are part of the Zig build")
class MpiDoctor(StorageFixture):
    def setUp(self):
        super().setUp()
        self.env["LMOD_CMD"] = "/usr/share/lmod/lmod/libexec/lmod"
        modules = self.root / "init" / "modules"
        (modules / "EESSI").mkdir(parents=True)
        (modules / "EESSI" / "2026.06.lua").write_text("-- module\n")
        self.env["MODULEPATH"] = str(modules)
        for name in ("OMPI_MCA_pml", "OMPI_MCA_mtl", "FI_PROVIDER", "SLURM_CPU_BIND",
                     "SLURM_CPU_BIND_LIST", "SLURM_MEM_BIND"):
            self.env.pop(name, None)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.host_path = self.env["PATH"]
        self.env["PATH"] = str(self.tools)
        script(self.tools / "fi_info", "#!/bin/sh\necho 'provider: tcp'\n")
        script(self.tools / "ucx_info", "#!/bin/sh\necho '# UCT version=1.16.0'\n")
        self.record = self.root / "mpirun-env"
        script(self.tools / "mpicc", """#!/bin/sh
out=
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; shift 2; continue; fi
  shift
done
/bin/cat > "$out" << 'END'
%sEND
/bin/chmod +x "$out"
""" % HELLO)
        script(self.tools / "mpirun", """#!/bin/sh
printf '%%s\\n' "pml=${OMPI_MCA_pml-}" "mtl=${OMPI_MCA_mtl-}" "fi=${FI_PROVIDER-}" >> %s
prog=
for a in "$@"; do prog=$a; done
"$prog"
""" % self.record)

    def site(self, transports):
        path = self.root / "site.toml"
        names = ", ".join(f'"{name}"' for name in transports)
        path.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "%u.%j"\n'
            'node_local_fstype = "xfs"\nshared_scratch = ["/scratch"]\n'
            f'[doctor]\nmpi_transports = [{names}]\n')
        path.chmod(0o644)
        return path

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return __import__("subprocess").run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_without_the_flag_nothing_is_compiled_and_a_build_sets_no_transport(self):
        run = self.run_tool(["--config", str(self.site(["ofi"])), "doctor"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("MPI", run.stdout)
        self.assertNotIn("fi_info", run.stdout)
        explained = self.run_tool(["--explain", "recipe.eb"], PATH=self.host_path)
        self.assertEqual(explained.returncode, 0, explained.stderr)
        self.assertNotIn("OMPI_MCA", explained.stdout)
        self.assertNotIn("FI_PROVIDER", explained.stdout)
        self.env["CONTROL_PATH_NAMES"] = "OMPI_MCA_pml OMPI_MCA_mtl FI_PROVIDER"
        built = self.run_tool(["recipe.eb"], PATH=self.host_path)
        self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
        seen = json.loads((self.root / "eb.json").read_text())
        self.assertIsNone(seen["paths"]["OMPI_MCA_pml"])
        self.assertIsNone(seen["paths"]["OMPI_MCA_mtl"])
        self.assertIsNone(seen["paths"]["FI_PROVIDER"])

    def test_an_allocation_runs_each_approved_transport_and_reports_the_override(self):
        run = self.run_tool(["--config", str(self.site(["ofi", "ucx"])), "doctor", "--mpi"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("info fi_info: provider: tcp", run.stdout)
        self.assertIn("info ucx_info: # UCT version=1.16.0", run.stdout)
        self.assertIn("info no Slurm CPU or memory bind is set", run.stdout)
        self.assertIn("ok   MPI ofi hello size 2 on cpus 0,1 with OMPI_MCA_pml=cm OMPI_MCA_mtl=ofi", run.stdout)
        self.assertIn("ok   MPI ucx hello size 2 on cpus 0,1 with OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi", run.stdout)
        recorded = self.record.read_text().splitlines()
        self.assertEqual(recorded, ["pml=cm", "mtl=ofi", "fi=", "pml=ucx", "mtl=^ofi", "fi="])
        shown = self.run_tool(["--config", str(self.site(["ofi"])), "config"])
        self.assertRegex(shown.stdout, r"doctor\.mpi_transports\s+ofi\s+\[site ")

    def test_shared_cpus_are_a_warning_and_a_user_file_cannot_name_a_transport(self):
        script(self.tools / "mpicc", """#!/bin/sh
out=
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; shift 2; continue; fi
  shift
done
/bin/cat > "$out" << 'END'
%sEND
/bin/chmod +x "$out"
""" % SHARED)
        run = self.run_tool(["--config", str(self.site(["ofi"])), "doctor", "--mpi"],
                            SLURM_CPU_BIND="cores", SLURM_CPU_BIND_LIST="0-1")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn MPI ofi hello ranks share cpu 0 with OMPI_MCA_pml=cm OMPI_MCA_mtl=ofi", run.stdout)
        self.assertIn("info Slurm bind SLURM_CPU_BIND=cores SLURM_CPU_BIND_LIST=0-1 SLURM_MEM_BIND=unset", run.stdout)

        home = self.root / "home"
        conf = home / ".config" / "eb-local"
        conf.mkdir(parents=True)
        (conf / "config.toml").write_text('[doctor]\nmpi_transports = ["ofi"]\n')
        (conf / "config.toml").chmod(0o600)
        refused = self.run_tool(["doctor", "--mpi"], HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"))
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("doctor.mpi_transports is a site setting", refused.stderr)

    def test_outside_an_allocation_the_hello_is_not_compiled(self):
        self.env.pop("SLURM_JOB_ID", None)
        run = self.run_tool(["--config", str(self.site(["ofi"])), "doctor", "--mpi"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("info MPI hello was not compiled; this shell is not inside an allocation", run.stdout)
        self.assertIn("info fi_info: provider: tcp", run.stdout)
        self.assertFalse(self.record.exists())

    def test_missing_tools_are_named_and_an_empty_list_compiles_nothing(self):
        for name in ("fi_info", "ucx_info", "mpicc", "mpirun"):
            (self.tools / name).unlink()
        run = self.run_tool(["--config", str(self.site(["ofi"])), "doctor", "--mpi"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("info fi_info is not on PATH", run.stdout)
        self.assertIn("info ucx_info is not on PATH", run.stdout)
        self.assertIn("info mpicc is not on PATH, so the MPI hello was not compiled", run.stdout)
        empty = self.run_tool(["doctor", "--mpi"])
        self.assertIn("info no site-approved MPI transport is configured", empty.stdout)
        self.assertNotIn("mpicc", empty.stdout)

    def test_mpi_hello_uses_tmpdir_and_leaves_cwd_clean(self):
        ro_cwd = self.root / "readonly-cwd"
        ro_cwd.mkdir()
        ro_cwd.chmod(0o555)
        self.addCleanup(lambda: ro_cwd.chmod(0o755))

        argv, env = binary.command(self.script, ["--config", str(self.site(["ofi"])), "doctor", "--mpi"], dict(self.env))
        run = __import__("subprocess").run(argv, env=env, cwd=ro_cwd, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("ok   MPI ofi hello size 2 on cpus 0,1", run.stdout)
        self.assertFalse((ro_cwd / ".zig-cache").exists())

        rw_cwd = self.root / "writable-cwd"
        rw_cwd.mkdir()
        run_rw = __import__("subprocess").run(argv, env=env, cwd=rw_cwd, capture_output=True, text=True)
        self.assertEqual(run_rw.returncode, 0, run_rw.stdout + run_rw.stderr)
        self.assertFalse((rw_cwd / ".zig-cache").exists())
