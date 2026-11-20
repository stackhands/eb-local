#!/usr/bin/env python3
"""eb-local list and eb-local doctor, through the command line of the Zig build.

list reads the trees EESSI-extend makes, one per EESSI version and CPU
target; doctor reports what would stop a build or a module load.
"""
import os
from pathlib import Path
import pwd
import re
import subprocess
import unittest

import binary
from test_storage import StorageFixture

SITE_DEFAULTS = Path(__file__).resolve().parents[1] / "docs" / "orgmode" / "howto" / "set-site-defaults.org"
DOCTOR_DEFAULT = Path(__file__).resolve().parent / "fixtures" / "doctor-without-workspace.txt"


def guide_block(language):
    """The one source block in LANGUAGE of the site defaults guide, unindented."""
    found = re.search(rf"^( *)#\+begin_src {language}\n(.*?)^\1#\+end_src$", SITE_DEFAULTS.read_text(), re.M | re.S)
    indent = len(found.group(1))
    return "".join(line[indent:] for line in found.group(2).splitlines(keepends=True))

# eessi-arch-guard --strict --shell: a reload, a guard that keeps the
# target, or one that cannot select a target.
GUARD = r'''#!/bin/sh
printf '%s\n' "$*" > "$CONTROL_ROOT/guard-args"
printf '%s\n' "$EESSI_ARCH_GUARD_WORKDIR" > "$CONTROL_ROOT/guard-workdir"
stat -c %a "$EESSI_ARCH_GUARD_WORKDIR" > "$CONTROL_ROOT/guard-workdir-mode"
case "${GUARD_DOUBLE:-reload}" in
    reload) echo "export EESSI_ARCH_GUARD_RELOADED='x86_64/amd/zen4->x86_64/amd/zen2'"
            echo "export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen2" ;;
    keep) ;;
    fail) echo "eessi-arch-guard: no software directory for x86_64/amd/zen4" >&2; exit 78 ;;
esac
'''


@unittest.skipUnless(binary.BIN, "list and doctor are features of the Zig build")
class ListAndDoctor(StorageFixture):
    def setUp(self):
        super().setUp()
        # The module double stands in for Lmod's, whose init sets LMOD_CMD,
        # and EESSI's init puts the directory of the EESSI module on MODULEPATH.
        self.env["LMOD_CMD"] = "/usr/share/lmod/lmod/libexec/lmod"
        self.eessi_modules = self.root / "init" / "modules"
        (self.eessi_modules / "EESSI").mkdir(parents=True)
        (self.eessi_modules / "EESSI" / "2026.06.lua").write_text("-- module\n")
        self.env["MODULEPATH"] = str(self.eessi_modules)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def install(self, target, module):
        tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / target
        name, version = module.split("/")
        (tree / "software" / name / version).mkdir(parents=True, exist_ok=True)
        lua = tree / "modules" / "all" / name / f"{version}.lua"
        lua.parent.mkdir(parents=True, exist_ok=True)
        lua.write_text("-- module\n")

    def two_targets(self):
        self.install("x86_64/amd/zen2", "GSL/2.8-GCC-15.2.0")
        self.install("x86_64/amd/zen2", "pigz/2.8-GCCcore-15.2.0")
        self.install("x86_64/amd/zen4", "GSL/2.8-GCC-15.2.0")

    # -- list ---------------------------------------------------------------

    def test_list_shows_each_module_for_each_target(self):
        self.two_targets()
        run = self.run_tool(["list"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        lines = run.stdout.splitlines()
        self.assertIn("2 module(s) for 2 CPU target(s)", lines[0])
        self.assertEqual(lines[1].split(), ["MODULE", "zen2", "zen4"])
        self.assertEqual(lines[2].split(), ["GSL/2.8-GCC-15.2.0", "x", "x"])
        self.assertEqual(lines[3].split(), ["pigz/2.8-GCCcore-15.2.0", "x", "-"])
        self.assertIn("Load EESSI", lines[-1])
        self.assertEqual([line for line in lines if line != line.rstrip()], [], "a line ends in a blank")

    def test_list_names_what_this_nodes_target_lacks(self):
        self.two_targets()
        run = self.run_tool(["list"], SLURM_JOB_ID="", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4", EESSI_VERSION="2026.06")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.splitlines()[1].split(), ["MODULE", "zen2", "zen4*"])
        self.assertIn("Not built for this node's target, x86_64/amd/zen4 (*): pigz/2.8-GCCcore-15.2.0.", run.stdout)
        run = self.run_tool(["list"], SLURM_JOB_ID="", EESSI_SOFTWARE_SUBDIR="x86_64/intel/icelake")
        self.assertIn("Nothing is built for this node's target, x86_64/intel/icelake", run.stdout)

    def test_list_narrows_to_names_and_versions(self):
        self.two_targets()
        for args in (["GSL"], ["GSL/2.8-GCC-15.2.0"]):
            with self.subTest(args=args):
                run = self.run_tool(["list"] + args, SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn("1 module(s)", run.stdout)
                self.assertNotIn("pigz", run.stdout)
        run = self.run_tool(["list", "GS"], SLURM_JOB_ID="")
        self.assertIn("Nothing that matches", run.stdout)
        self.assertEqual(self.run_tool(["list", "--all"], SLURM_JOB_ID="").returncode, 2)

    def test_list_without_missing_is_unchanged_raw_bytes(self):
        self.two_targets()
        argv, env = binary.command(
            self.script,
            ["list"],
            dict(
                self.env,
                SLURM_JOB_ID="",
                EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
                EESSI_VERSION="2026.06",
            ),
        )
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        expected = (
            f"{self.prefix}: 2 module(s) for 2 CPU target(s)\n"
            "MODULE                   zen2  zen4*\n"
            "GSL/2.8-GCC-15.2.0       x     x\n"
            "pigz/2.8-GCCcore-15.2.0  x     -\n"
            "Not built for this node's target, x86_64/amd/zen4 (*): pigz/2.8-GCCcore-15.2.0.\n"
            "Build them in an allocation on this node type; each target needs its own build.\n"
        ).encode()
        self.assertEqual((run.returncode, run.stdout, run.stderr), (0, expected, b""))

    def test_list_missing_prints_only_missing_modules_for_this_node(self):
        self.two_targets()
        missing = self.run_tool(
            ["list", "--missing"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
            EESSI_VERSION="2026.06",
        )
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertEqual(missing.stdout, "pigz/2.8-GCCcore-15.2.0\n")

        filtered = self.run_tool(
            ["list", "--missing", "GSL"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
            EESSI_VERSION="2026.06",
        )
        self.assertEqual((filtered.returncode, filtered.stdout, filtered.stderr), (0, "", ""))

        empty_target = self.run_tool(
            ["list", "--missing"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/intel/icelake",
            EESSI_VERSION="2026.06",
        )
        self.assertEqual(empty_target.returncode, 0, empty_target.stderr)
        self.assertEqual(
            empty_target.stdout,
            "GSL/2.8-GCC-15.2.0\npigz/2.8-GCCcore-15.2.0\n",
        )

        no_eessi = self.run_tool(["list", "--missing"], SLURM_JOB_ID="")
        self.assertEqual(no_eessi.returncode, 2)
        self.assertIn("needs EESSI loaded", no_eessi.stderr)

        conflict = self.run_tool(
            ["list", "--missing", "--json"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
        )
        self.assertEqual(conflict.returncode, 2)
        self.assertIn("--missing or --json", conflict.stderr)

    def test_list_matches_software_subdir_with_trailing_slash(self):
        self.two_targets()
        missing = self.run_tool(
            ["list", "--missing"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4/",
            EESSI_VERSION="2026.06",
        )
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertEqual(missing.stdout, "pigz/2.8-GCCcore-15.2.0\n")

        listing = self.run_tool(
            ["list"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4/",
            EESSI_VERSION="2026.06",
        )
        self.assertEqual(listing.returncode, 0, listing.stderr)
        self.assertEqual(listing.stdout.splitlines()[1].split(), ["MODULE", "zen2", "zen4*"])

    def test_list_of_an_empty_prefix_and_a_symlinked_tree(self):
        run = self.run_tool(["list"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("Nothing is installed", run.stdout)
        elsewhere = self.root / "elsewhere"
        self.prefix.mkdir(parents=True)
        (elsewhere / "versions").mkdir(parents=True)
        os.symlink(elsewhere / "versions", self.prefix / "versions")
        real = elsewhere / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen2"
        (real / "software").mkdir(parents=True)
        (real / "modules" / "all" / "x").mkdir(parents=True)
        (real / "modules" / "all" / "x" / "1.lua").write_text("")
        run = self.run_tool(["list"], SLURM_JOB_ID="")
        self.assertIn("Nothing is installed", run.stdout)

    # -- doctor -------------------------------------------------------------

    def test_doctor_in_a_good_allocation_finds_nothing_that_stops_a_build(self):
        run = self.run_tool(["doctor"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   Slurm job 123: build space {self.job}", run.stdout)
        self.assertIn("does not exist yet; the first build creates it", run.stdout)
        self.assertNotIn("FAIL", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))
        self.assertFalse(self.prefix.exists())

    def test_doctor_without_workspace_is_byte_identical(self):
        clean = {
            name: ""
            for name in (
                "PERL5LIB", "PYTHONPATH", "R_LIBS", "R_LIBS_USER",
                "CMAKE_PREFIX_PATH", "PKG_CONFIG_PATH", "LD_LIBRARY_PATH",
                "LD_PRELOAD", "LD_AUDIT",
                "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH", "NODE_PATH",
                "CARGO_BUILD_RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER",
                "R_MAKEVARS_USER", "R_MAKEVARS_SITE", "RUSTFLAGS",
            )
        }
        for key in os.environ:
            if key.startswith("CARGO_TARGET_") and key.endswith(("_LINKER", "_RUSTFLAGS")):
                clean[key] = ""
        run = self.run_tool(["doctor"], **clean)
        expected = DOCTOR_DEFAULT.read_text().format(
            root=self.root,
            user=pwd.getpwuid(os.getuid()).pw_name,
            timezone=os.path.realpath("/etc/localtime"),
        )
        self.assertEqual((run.returncode, run.stdout.encode(), run.stderr.encode()),
                         (0, expected.encode(), b""))

    def test_doctor_workspace_probes_a_private_node_local_path(self):
        workspace = self.job / "candidate"
        cache = workspace / "cache"
        cache.mkdir(parents=True)
        run = self.run_tool(
            ["doctor", "--workspace", str(workspace)],
            XDG_CACHE_HOME=str(cache),
            EB_LOCAL_TEST_WORKSPACE_CAPACITY="987654321:4321",
            EB_LOCAL_TEST_WORKSPACE_EXEC="ok",
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   workspace {workspace}: created, wrote, renamed, executed and removed a probe\n", run.stdout)
        self.assertIn(f"info workspace {workspace}: xfs file system, classified node-local\n", run.stdout)
        self.assertIn(f"info workspace {workspace}: 987654321 free bytes, 4321 free inodes\n", run.stdout)
        self.assertIn(f"ok   workspace {workspace}: mount {self.job} does not have noexec\n", run.stdout)
        self.assertIn(f"ok   effective XDG cache {cache} is private to workspace {workspace}\n", run.stdout)
        self.assertEqual(list(workspace.iterdir()), [cache])

    def test_doctor_workspace_reports_shared_noexec_and_failed_execution(self):
        workspace = self.root / "shared" / "candidate"
        workspace.mkdir(parents=True)
        argv, env = binary.command(
            self.script,
            ["doctor", "--workspace", str(workspace)],
            dict(
                self.env,
                EB_LOCAL_TEST_WORKSPACE_CAPACITY="20:3",
                EB_LOCAL_TEST_WORKSPACE_EXEC="fail",
            ),
        )
        mountinfo = Path(env["EB_LOCAL_TEST_MOUNTINFO"])
        with mountinfo.open("a") as table:
            table.write(f"3 1 0:3 / {workspace} rw,noexec - nfs server:/workspace rw\n")
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("execute=failed, remove=ok", run.stdout)
        self.assertIn(f"info workspace {workspace}: nfs file system, classified shared\n", run.stdout)
        self.assertIn(f"FAIL workspace {workspace}: mount {workspace} has noexec\n", run.stdout)
        self.assertEqual(list(workspace.iterdir()), [])

    def test_doctor_workspace_fails_when_bytes_or_inodes_are_zero(self):
        workspace = self.job / "full-candidate"
        workspace.mkdir(parents=True)
        for cap in ("0:10", "100:0"):
            with self.subTest(cap=cap):
                run = self.run_tool(
                    ["doctor", "--workspace", str(workspace)],
                    EB_LOCAL_TEST_WORKSPACE_CAPACITY=cap,
                    EB_LOCAL_TEST_WORKSPACE_EXEC="ok",
                )
                self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                self.assertIn(f"FAIL workspace {workspace} has no space left on device", run.stdout)

    def test_doctor_workspace_reports_real_noexec_mount_execution_failure(self):
        import shlex
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            mountpoint = Path(tmp) / "noexec-ws"
            mountpoint.mkdir()
            probe = subprocess.run(
                ["unshare", "-U", "-r", "-m", "sh", "-c",
                 f'mount -t tmpfs -o noexec,size=1m tmpfs "{mountpoint}" && umount "{mountpoint}"'],
                capture_output=True,
                text=True,
            )
            if probe.returncode != 0:
                self.skipTest(f"unprivileged noexec mount unavailable: {probe.stderr.strip()}")
            argv, env = binary.command(
                self.script,
                ["doctor", "--workspace", str(mountpoint)],
                self.env,
            )
            env.pop("EB_LOCAL_TEST_MOUNTINFO", None)
            env.pop("EB_LOCAL_TEST_WORKSPACE_EXEC", None)
            quoted_mp = shlex.quote(str(mountpoint))
            quoted_cmd = " ".join(shlex.quote(a) for a in argv)
            script = (
                f"mount -t tmpfs -o noexec,size=1m tmpfs {quoted_mp} && "
                f"trap 'umount {quoted_mp} >/dev/null 2>&1 || true' EXIT && "
                f"{quoted_cmd}"
            )
            run = subprocess.run(
                ["unshare", "-U", "-r", "-m", "sh", "-c", script],
                env=env,
                cwd=self.root,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
            self.assertIn("probe create=ok, write=ok, rename=ok, execute=failed, remove=ok", run.stdout, run.stdout + run.stderr)
            self.assertIn(f"FAIL workspace {mountpoint}: mount {mountpoint} has noexec\n", run.stdout)
            self.assertEqual(list(mountpoint.iterdir()), [])

    def test_doctor_rejects_duplicate_workspace_flag(self):
        ws1 = self.root / "ws1"
        ws2 = self.root / "ws2"
        ws1.mkdir()
        ws2.mkdir()
        run = self.run_tool(["doctor", "--workspace", str(ws1), "--workspace", str(ws2)], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn("doctor takes one --workspace", run.stderr)

    def test_doctor_reports_an_xalt_only_preload_as_info(self):
        xalt = "/opt/xalt/current/lib64/libxalt_init.so:"
        run = self.run_tool(["doctor"], LD_PRELOAD=xalt)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("info LD_PRELOAD loads only XALT's libxalt_init.so", run.stdout)
        self.assertNotIn("warn LD_PRELOAD is set", run.stdout)
        run = self.run_tool(["doctor"], LD_PRELOAD=xalt + "/home/u/other.so")
        self.assertIn("warn LD_PRELOAD is set", run.stdout)
        self.assertNotIn("XALT", run.stdout)

    def test_doctor_names_variables_left_in_the_shell(self):
        run = self.run_tool(["doctor"], EASYBUILD_INSTALLPATH="/elsewhere", LD_LIBRARY_PATH="/host/lib",
                            EESSI_USER_INSTALL=str(self.prefix))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn EASYBUILD_INSTALLPATH=/elsewhere is set in this shell", run.stdout)
        self.assertIn("warn LD_LIBRARY_PATH is set", run.stdout)
        self.assertIn("ok   EESSI_USER_INSTALL names your prefix", run.stdout)

    def test_doctor_takes_what_eessi_extend_set_for_eb_local_env_as_its_own(self):
        # eval "$(eb-local env)" loads EESSI-extend once the prefix exists, and
        # the extension sets the install path and EasyBuild's prefix.
        self.prefix.mkdir(parents=True)
        tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        shell = dict(EESSI_USER_INSTALL=str(self.prefix), EASYBUILD_INSTALLPATH=str(tree),
                     EASYBUILD_PREFIX="/tmp/u/easybuild",
                     LOADEDMODULES="EESSI/2026.06:EasyBuild/5.4.2:EESSI-extend/2026.06-easybuild")
        run = self.run_tool(["doctor"], **shell)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("warn EASYBUILD", run.stdout)
        self.assertIn("ok   EASYBUILD_INSTALLPATH is in your prefix, as EESSI-extend sets it when eb-local env loads it\n", run.stdout)
        self.assertIn("ok   EASYBUILD_PREFIX is EESSI-extend's own, set when eb-local env loads it\n", run.stdout)
        # Without the extension loaded, or with its install path elsewhere,
        # they are what an earlier session left.
        for change in ({"LOADEDMODULES": "EESSI/2026.06"}, {"EASYBUILD_INSTALLPATH": "/elsewhere"}):
            with self.subTest(**change):
                run = self.run_tool(["doctor"], **dict(shell, **change))
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn("warn EASYBUILD_PREFIX=/tmp/u/easybuild is set in this shell", run.stdout)
                self.assertIn("warn EASYBUILD_INSTALLPATH=", run.stdout)

    def login(self, home, **extra):
        """What the guide's login script leaves in EESSI_USER_INSTALL."""
        script = guide_block("sh") + 'printf %s "${EESSI_USER_INSTALL-unset}"\n'
        run = subprocess.run(["sh", "-c", script], env={"PATH": os.environ["PATH"], "HOME": str(home), **extra},
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout

    def test_the_guide_default_for_a_site_is_one_prefix_for_eb_local_and_eessi_extend(self):
        line = guide_block("toml").strip()
        self.assertRegex(line, r"^prefix = ")
        home = self.root / "home"
        home.mkdir()
        exported = self.login(home)
        self.assertEqual(exported, f"{home}/.local/eessi")
        self.assertEqual(os.stat(exported).st_mode & 0o777, 0o700)
        site = self.root / "site.toml"
        site.write_text(f'{line}\n\n[storage]\nnode_local_root = "{self.nodes}"\nnode_local_fstype = "xfs"\n'
                        'shared_scratch = ["/scratch"]\n')
        site.chmod(0o644)
        del self.env["EB_LOCAL_PREFIX"]
        run = self.run_tool(["doctor"], HOME=str(home), EB_LOCAL_CONFIG=str(site), EESSI_USER_INSTALL=exported)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"ok   installs go to {home}/.local/eessi: a user install, prefix from site {site}:1\n", run.stdout)
        self.assertIn("ok   EESSI_USER_INSTALL names your prefix", run.stdout)
        self.assertNotIn("warn EESSI_USER_INSTALL", run.stdout)

    def test_the_guide_login_script_leaves_a_shell_with_an_install_variable_alone(self):
        home = self.root / "home"
        home.mkdir()
        for name in ("EESSI_USER_INSTALL", "EESSI_PROJECT_INSTALL", "EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL"):
            with self.subTest(name=name):
                self.assertEqual(self.login(home, **{name: ""}), "" if name == "EESSI_USER_INSTALL" else "unset")
                self.assertFalse((home / ".local").exists())

    def guard_path(self):
        bin = self.root / "guard-bin"
        bin.mkdir()
        (bin / "eessi-arch-guard").write_text(GUARD)
        (bin / "eessi-arch-guard").chmod(0o755)
        return f"{bin}:/usr/bin:/bin"

    def test_doctor_shows_the_target_eessi_arch_guard_selects_in_a_job(self):
        loaded = dict(EESSI_ARCH_GUARD="", PATH=self.guard_path(), EESSI_VERSION="2026.06",
                      EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        run = self.run_tool(["doctor"], **loaded)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("ok   eessi-arch-guard selects x86_64/amd/zen2 here, not x86_64/amd/zen4, which EESSI is"
                      " loaded for; builds, env and dev use x86_64/amd/zen2\n", run.stdout)
        # Asked as a build asks it, with a private directory of its own.
        self.assertEqual((self.root / "guard-args").read_text(), "--strict --shell\n")
        self.assertEqual((self.root / "guard-workdir-mode").read_text(), "700\n")
        workdir = Path((self.root / "guard-workdir").read_text().strip())
        self.assertEqual(workdir.parent, self.job)
        self.assertFalse(workdir.exists())
        self.assertEqual(list(self.job.iterdir()), [])
        run = self.run_tool(["doctor"], GUARD_DOUBLE="keep", **loaded)
        self.assertIn("ok   eessi-arch-guard selects x86_64/amd/zen4, the target EESSI is loaded for\n", run.stdout)
        run = self.run_tool(["doctor"], GUARD_DOUBLE="fail", **loaded)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("warn eessi-arch-guard cannot select a target here (exit 78: eessi-arch-guard: no software"
                      " directory for x86_64/amd/zen4); builds stop when it cannot, and EESSI_ARCH_GUARD=0 turns it off\n",
                      run.stdout)

    def test_doctor_asks_eessi_arch_guard_only_in_a_job_with_eessi_loaded(self):
        on_path = dict(EESSI_ARCH_GUARD="", PATH=self.guard_path(), EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        for outside in (dict(SLURM_JOB_ID=""), dict(EESSI_SOFTWARE_SUBDIR="")):
            run = self.run_tool(["doctor"], **dict(on_path, **outside))
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("info eessi-arch-guard is on PATH; builds, env and dev load EESSI for the target it selects,"
                          " which doctor shows inside a job with EESSI loaded\n", run.stdout)
        run = self.run_tool(["doctor"], **dict(on_path, EESSI_ARCH_GUARD="0"))
        self.assertIn("info eessi-arch-guard is on PATH, and EESSI_ARCH_GUARD=0 turns it off\n", run.stdout)
        self.assertFalse((self.root / "guard-args").exists())
        run = self.run_tool(["doctor"], EESSI_ARCH_GUARD="", PATH="/usr/bin:/bin")
        self.assertIn("info eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI"
                      " detects\n", run.stdout)

    def test_doctor_says_what_is_wrong_with_the_node_local_mount_and_what_to_change(self):
        run = self.run_tool(["doctor"], CONTROL_FSTYPE="tmpfs")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn(f"FAIL Slurm job 123: the node-local mount {self.job} is on tmpfs, not xfs; builds refuse it. "
                      "A build's workspace must be on node-local disk, not shared or memory-backed storage; "
                      f"storage.node_local_fstype, xfs [site {self.config}:3], names the nodes' file system", run.stdout)

    def test_doctor_names_where_a_refused_prefix_and_its_storage_were_set(self):
        shared = self.root / "shared" / "install"
        run = self.run_tool(["doctor"], EB_LOCAL_PREFIX=str(shared))
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn(f"FAIL the install prefix {shared} [environment EB_LOCAL_PREFIX] is under {shared.parent}, shared "
                      f"scratch in storage.shared_scratch [site {self.config}:4]; builds refuse it. Installs, sources and "
                      "logs must outlive the job and not be on shared scratch; set a prefix on durable storage you own "
                      "with prefix in your eb-local configuration, EB_LOCAL_PREFIX, or --project DIR for a project\n",
                      run.stdout)

    def test_doctor_refuses_a_prefix_under_a_linked_node_local_root(self):
        real = self.root / "real-nodes"
        real.mkdir()
        link = self.root / "nodes-link"
        link.symlink_to(real)
        prefix = real / "install"
        site = self.root / "linked-root.toml"
        site.write_text(
            f'[storage]\nnode_local_root = "{link}"\nnode_local_mount = "%u.%j"\n'
            'node_local_fstype = "xfs"\nshared_scratch = ["/scratch"]\n',
            encoding="utf-8",
        )
        site.chmod(0o644)
        run = self.run_tool(
            ["--config", str(site), "doctor"],
            EB_LOCAL_PREFIX=str(prefix),
            SLURM_JOB_ID="",
        )
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn(
            f"FAIL the install prefix {prefix} [environment EB_LOCAL_PREFIX] is under {real}, ",
            run.stdout,
        )
        self.assertIn("node-local storage below storage.node_local_root", run.stdout)
        self.assertEqual(run.stdout.count("FAIL the install prefix"), 1)

    def test_doctor_fails_on_a_project_directory_others_can_write(self):
        project = self.root / "durable" / "project"
        project.mkdir(parents=True)
        project.chmod(0o2777)
        run = self.run_tool(["doctor", "--project", str(project)])
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL project directory", run.stdout)
        self.assertIn("writable by others", run.stdout)
        project.chmod(0o770)
        run = self.run_tool(["doctor", "--project", str(project)])
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("warn project directory", run.stdout)
        self.assertIn("chmod g+s", run.stdout)

    def test_doctor_outside_an_allocation_and_with_modules_off_modulepath(self):
        self.install("x86_64/amd/zen2", "GSL/2.8-GCC-15.2.0")
        run = self.run_tool(["doctor"], SLURM_JOB_ID="", MODULEPATH=f"/somewhere/else:{self.eessi_modules}")
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("info not in a Slurm job", run.stdout)
        self.assertIn("warn your modules are not on MODULEPATH", run.stdout)
        inside = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen2" / "modules" / "all"
        run = self.run_tool(["doctor"], SLURM_JOB_ID="", MODULEPATH=f"/somewhere/else:{self.eessi_modules}:{inside}")
        self.assertIn("ok   your modules are on MODULEPATH", run.stdout)
        self.assertEqual(self.run_tool(["doctor", "extra"]).returncode, 2)

    def test_doctor_fails_where_no_directory_on_modulepath_holds_the_eessi_module(self):
        # A shell with Lmod but without EESSI's init: builds keep its
        # MODULEPATH, and Lmod cannot find EESSI/2026.06 there.
        repo = self.root / "repo"
        for modulepath in ("", "/somewhere/else"):
            with self.subTest(MODULEPATH=modulepath):
                run = self.run_tool(["doctor"], MODULEPATH=modulepath, EESSI_CVMFS_REPO=str(repo))
                self.assertEqual(run.returncode, 1, run.stdout)
                self.assertIn("FAIL no directory on MODULEPATH in this shell holds stack.module, EESSI/2026.06 [default], "
                              "so builds, env and dev cannot load it; "
                              f"module use {repo}/init/modules adds EESSI's module directory\n", run.stdout)
                self.assertTrue(run.stdout.rstrip().endswith("Something above says FAIL; builds stop there."))
        # A Tcl module file has no extension; a name without a version is a directory.
        tcl = self.root / "tcl"
        (tcl / "EESSI").mkdir(parents=True)
        (tcl / "EESSI" / "2026.06").write_text("#%Module\n")
        for extra in ({}, {"EB_LOCAL_STACK_MODULE": "EESSI"}):
            with self.subTest(**extra):
                run = self.run_tool(["doctor"], MODULEPATH=f"/somewhere/else:{tcl}", **extra)
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assertNotIn("holds stack.module", run.stdout)
        run = self.run_tool(["doctor"], EB_LOCAL_STACK_MODULE="site/eessi")
        self.assertIn("holds stack.module, site/eessi [environment EB_LOCAL_STACK_MODULE], so", run.stdout)
        # With no module command, a build sources an init, which sets MODULEPATH.
        run = self.run_tool(["doctor"], LMOD_CMD="", MODULESHOME="", MODULEPATH="")
        self.assertNotIn("holds stack.module", run.stdout)
        run = self.without_a_site_file(MODULEPATH="")
        self.assertIn("warn no directory on MODULEPATH in this shell holds stack.module", run.stdout)

    def test_doctor_fails_on_a_secret_every_build_would_stop_on(self):
        secret = dict(EB_LOCAL_SECRET_MY_LICENCE_KEY="env:MY_LICENCE_SRC")
        run = self.run_tool(["doctor"], **secret)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL secret MY_LICENCE_KEY: MY_LICENCE_SRC is not set", run.stdout)
        self.assertIn("every build stops there, whether or not it uses MY_LICENCE_KEY. Name in build.secrets the "
                      "secrets builds need, or in EB_LOCAL_BUILD_SECRETS those one build needs\n", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Something above says FAIL; builds stop there."))
        build = self.run_wrapper(["recipe.eb"], **secret)
        self.assertEqual(build.returncode, 2, build.stdout + build.stderr)
        self.assertIn("MY_LICENCE_SRC is not set", build.stderr)

        value = "licence-value-27000"
        run = self.run_tool(["doctor"], MY_LICENCE_SRC=value, **secret)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("ok   secret MY_LICENCE_KEY can be read from env:MY_LICENCE_SRC", run.stdout)
        self.assertNotIn(value, run.stdout + run.stderr)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))
        run = self.run_tool(["doctor"], MY_LICENCE_SRC="x7q", **secret)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("warn secret MY_LICENCE_KEY from env:MY_LICENCE_SRC is shorter than 4 bytes", run.stdout)
        self.assertNotIn("x7q", run.stdout + run.stderr)

        run = self.without_a_site_file(**secret)
        self.assertIn("warn secret MY_LICENCE_KEY: MY_LICENCE_SRC is not set", run.stdout)

    def test_doctor_fails_only_on_a_secret_builds_get(self):
        secret = dict(EB_LOCAL_SECRET_MY_LICENCE_KEY="env:MY_LICENCE_SRC", EB_LOCAL_SECRET_MIRROR_TOKEN="env:MY_MIRROR")
        run = self.run_tool(["doctor"], EB_LOCAL_BUILD_SECRETS="MIRROR_TOKEN", MY_MIRROR="mirror-token-value", **secret)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn("warn secret MY_LICENCE_KEY: MY_LICENCE_SRC is not set [environment EB_LOCAL_SECRET_MY_LICENCE_KEY]; "
                      "builds do not read it, as build.secrets [environment EB_LOCAL_BUILD_SECRETS] does not name it, "
                      "but one that names it stops there\n", run.stdout)
        self.assertIn("ok   secret MIRROR_TOKEN can be read from env:MY_MIRROR\n", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))
        build = self.run_wrapper(["recipe.eb"], EB_LOCAL_BUILD_SECRETS="MIRROR_TOKEN", MY_MIRROR="mirror-token-value", **secret)
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)

        run = self.run_tool(["doctor"], EB_LOCAL_BUILD_SECRETS="MY_LICENCE_KEY", MY_MIRROR="mirror-token-value", **secret)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL secret MY_LICENCE_KEY: MY_LICENCE_SRC is not set [environment EB_LOCAL_SECRET_MY_LICENCE_KEY]; "
                      "every build stops there, as build.secrets [environment EB_LOCAL_BUILD_SECRETS] names MY_LICENCE_KEY\n",
                      run.stdout)
        self.assertIn("info secret MIRROR_TOKEN can be read from env:MY_MIRROR; builds do not get it, as build.secrets "
                      "[environment EB_LOCAL_BUILD_SECRETS] does not name it\n", run.stdout)
        self.assertNotIn("mirror-token-value", run.stdout + run.stderr)

    def without_a_site_file(self, **extra):
        for installed in ("/etc/eb-local/config.toml", "/etc/eb-local.conf"):
            if Path(installed).exists():
                self.skipTest(f"{installed} is this host's site file")
        repo = self.root / "repo"
        return self.run_tool(["doctor"], EB_LOCAL_CONFIG="", XDG_CONFIG_HOME=str(self.root / "xdg"),
                             SLURM_JOB_ID="", EESSI_CVMFS_REPO=str(repo), **extra)

    def test_doctor_without_a_site_file_judges_eb_local_eb(self):
        init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        run = self.without_a_site_file()
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("info no site file sets storage.node_local_root: `eb-local RECIPE` needs a site file; "
                      "`eb-local eb` does not.", run.stdout)
        self.assertIn(f"FAIL {init} is missing, so `eb-local eb` stops", run.stdout)
        self.assertEqual(run.stdout.count("FAIL"), 2, run.stdout)

        init.parent.mkdir(parents=True)
        init.write_text("")
        run = self.without_a_site_file()
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertNotIn("FAIL", run.stdout)
        self.assertIn(f"ok   `eb-local eb` sources {init}", run.stdout)
        self.assertIn("ok   `eb-local eb` makes a user install into the module's default, $HOME/eessi", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith(
            "Nothing above stops `eb-local eb`; `eb-local RECIPE` needs a site file."), run.stdout)

        # EESSI-extend refuses to load for a project directory that is not there.
        project = self.root / "project"
        run = self.without_a_site_file(EESSI_PROJECT_INSTALL=str(project))
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn(f"FAIL EESSI_PROJECT_INSTALL={project} is not a directory, so EESSI-extend refuses to load "
                      "and `eb-local eb` stops", run.stdout)
        project.mkdir()
        run = self.without_a_site_file(EESSI_PROJECT_INSTALL=str(project))
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn(f"ok   `eb-local eb` makes a project install: EESSI_PROJECT_INSTALL={project}", run.stdout)

        run = self.without_a_site_file(EESSI_USER_INSTALL="/home/alice/eessi", EESSI_SITE_INSTALL="")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("FAIL more than one of EESSI_USER_INSTALL", run.stdout)
        self.assertIn("so `eb-local eb` refuses to run", run.stdout)

    def test_doctor_with_a_site_file_judges_builds_and_warns_for_eb_local_eb(self):
        run = self.run_tool(["doctor"], EESSI_CVMFS_REPO=str(self.root / "repo"),
                            EESSI_USER_INSTALL=str(self.prefix), EESSI_SITE_INSTALL="")
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertNotIn("FAIL", run.stdout)
        self.assertIn("is missing, so `eb-local eb` stops", run.stdout)
        self.assertIn("warn more than one of EESSI_USER_INSTALL", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("Nothing above stops a build."))
        project = self.root / "project"
        run = self.run_tool(["doctor"], EESSI_CVMFS_REPO=str(self.root / "repo"), EESSI_PROJECT_INSTALL=str(project))
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertIn(f"warn EESSI_PROJECT_INSTALL={project} is not a directory, so EESSI-extend refuses to load "
                      "and `eb-local eb` stops", run.stdout)

    def test_doctor_strict_promotes_warn_lines_to_failures(self):
        import json

        clean = {
            name: ""
            for name in (
                "PERL5LIB", "PYTHONPATH", "R_LIBS", "R_LIBS_USER",
                "CMAKE_PREFIX_PATH", "PKG_CONFIG_PATH", "LD_LIBRARY_PATH",
                "LD_PRELOAD", "LD_AUDIT",
                "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH", "NODE_PATH",
                "CARGO_BUILD_RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER",
                "R_MAKEVARS_USER", "R_MAKEVARS_SITE", "RUSTFLAGS",
            )
        }
        for key in os.environ:
            if key.startswith("CARGO_TARGET_") and key.endswith(("_LINKER", "_RUSTFLAGS")):
                clean[key] = ""
        # Default doctor passes in raw bytes even when a warn line appears.
        argv, env = binary.command(self.script, ["doctor"], dict(self.env, **dict(clean, LD_LIBRARY_PATH="/host/lib")))
        default_warn = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(default_warn.returncode, 0, default_warn.stderr)
        self.assertEqual(default_warn.stderr, b"")
        self.assertIn(b"warn LD_LIBRARY_PATH is set", default_warn.stdout)
        self.assertTrue(default_warn.stdout.endswith(b"Nothing above stops a build.\n"))

        # Without warnings or failures, --strict passes.
        repo = self.root / "repo"
        init = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init.parent.mkdir(parents=True)
        init.write_text("")
        tools_bin = self.root / "tools-bin"
        tools_bin.mkdir()
        (tools_bin / "rtrash").write_text("#!/bin/sh\nexit 0\n")
        (tools_bin / "rtrash").chmod(0o755)
        no_warn = dict(clean, EESSI_CVMFS_REPO=str(repo), PATH=f"{tools_bin}:{os.environ['PATH']}")
        ok_strict = self.run_tool(["doctor", "--strict"], **no_warn)
        self.assertEqual(ok_strict.returncode, 0, ok_strict.stdout + ok_strict.stderr)
        self.assertTrue(ok_strict.stdout.rstrip().endswith("Nothing above stops a build."))

        # With a warning, --strict exits 1 in both human and JSON modes.
        warn_strict = self.run_tool(["doctor", "--strict"], **dict(no_warn, LD_LIBRARY_PATH="/host/lib"))
        self.assertEqual(warn_strict.returncode, 1, warn_strict.stdout + warn_strict.stderr)
        self.assertIn("warn LD_LIBRARY_PATH is set", warn_strict.stdout)
        self.assertTrue(warn_strict.stdout.rstrip().endswith(
            "Something above says warn (--strict); warnings fail under --strict."))

        json_strict = self.run_tool(["doctor", "--strict", "--json"], **dict(no_warn, LD_LIBRARY_PATH="/host/lib"))
        self.assertEqual(json_strict.returncode, 1, json_strict.stdout + json_strict.stderr)
        doc = json.loads(json_strict.stdout)
        self.assertTrue(doc["failed"])
        self.assertEqual(doc["summary"], "Something above says warn (--strict); warnings fail under --strict.")
        self.assertTrue(any(line["level"] == "warn" for line in doc["lines"]))

        # When FAIL already occurred, --strict keeps the FAIL summary.
        fail_strict = self.run_tool(["doctor", "--strict"], **dict(clean, SLURM_JOB_ID="bogus", LD_LIBRARY_PATH="/host/lib"))
        self.assertEqual(fail_strict.returncode, 1, fail_strict.stdout + fail_strict.stderr)
        self.assertTrue(fail_strict.stdout.rstrip().endswith("Something above says FAIL; builds stop there."))

    def test_doctor_recognizes_symlinked_modulepath_under_prefix(self):
        real_prefix = self.root / "real-prefix"
        mod_dir = real_prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4" / "modules" / "all"
        mod_dir.mkdir(parents=True)
        sym_prefix = self.root / "sym-prefix"
        sym_prefix.symlink_to(real_prefix)
        sym_mod_dir = sym_prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4" / "modules" / "all"

        run = self.run_tool(
            ["doctor"],
            SLURM_JOB_ID="",
            EB_LOCAL_PREFIX=str(real_prefix),
            MODULEPATH=f"{self.eessi_modules}:{sym_mod_dir}",
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("ok   your modules are on MODULEPATH", run.stdout)
        self.assertNotIn("your modules are not on MODULEPATH", run.stdout)


if __name__ == "__main__":
    unittest.main()
