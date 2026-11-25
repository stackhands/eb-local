"""Exercise storage refusal and workspace routing with controlled mount metadata."""
import json
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

import binary

SCRIPT = Path(__file__).resolve().parents[1] / "eb-local"
MUTABLE = (
    "WORKING_DIR", "TMPDIR", "TMP", "TEMP", "EASYBUILD_BUILDPATH",
    "EASYBUILD_TMPDIR", "XDG_CACHE_HOME", "CARGO_HOME",
)
DURABLE = ("EASYBUILD_SOURCEPATH", "EASYBUILD_TMP_LOGDIR")
DOUBLE = r'''
findmnt() {
    case "$3" in
        FSTYPE) printf '%s\n' "${CONTROL_FSTYPE:-xfs}";;
        TARGET) printf '%s\n' "${CONTROL_MOUNT_TARGET:-$CONTROL_JOB_ROOT}";;
        OPTIONS) printf '%s\n' "${CONTROL_MOUNT_OPTIONS:-rw,relatime}";;
        *) return 99;;
    esac
}
stat() {
    if [ "$*" = "-c %u -- $CONTROL_JOB_ROOT" ] && [ -n "${CONTROL_OWNER:-}" ]; then
        printf '%s\n' "$CONTROL_OWNER"
    else command stat "$@"; fi
}
module() {
    if [ "$1" = unload ]; then
        export TMPDIR=/scratch/restored WORKING_DIR=/scratch/restored
        export EASYBUILD_BUILDPATH=/scratch/restored
        return 0
    fi
    if [ "$1" = load ]; then
        python3 "$CONTROL_ROOT/capture.py" load "$@" || return
        export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4 EESSI_ACCELERATOR_TARGET= EESSI_VERSION=2026.06
        export EASYBUILD_HOOKS=/selected/hooks.py
        export TMPDIR=/scratch/module WORKING_DIR=/scratch/module
        export EASYBUILD_BUILDPATH=/scratch/module
        # The install path EESSI-extend sets, or CONTROL_INSTALLPATH; and
        # CONTROL_LOAD_SETS, NAME=VALUE, as a site load hook would set it.
        case "$2" in
            EESSI-extend|EESSI-extend/*)
                export EASYBUILD_INSTALLPATH="${CONTROL_INSTALLPATH:-${EESSI_USER_INSTALL:-${EESSI_PROJECT_INSTALL:-$HOME/eessi}}/versions/2026.06/software/linux/x86_64/amd/zen4}"
                [ -z "${CONTROL_LOAD_SETS:-}" ] || export "$CONTROL_LOAD_SETS";;
        esac
        return 0
    fi
    return 99
}
eb() { python3 "$CONTROL_ROOT/capture.py" eb "$@"; }
export -f findmnt stat module eb
'''
CAPTURE = r'''
import json,os,sys
from pathlib import Path
root=Path(os.environ["CONTROL_ROOT"])
names=os.environ["CONTROL_PATH_NAMES"].split()
result={"paths":{name:os.environ.get(name) for name in names},"argv":sys.argv[2:],
        "user":os.environ.get("EESSI_USER_INSTALL"),
        "project":os.environ.get("EESSI_PROJECT_INSTALL"),
        "eessi_custom":os.environ.get("EESSI_CUSTOM_SITE_OPT"),
        "site_toolchains":os.environ.get("EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"),
        "hooks":os.environ.get("EASYBUILD_HOOKS"),
        "ld_library_path":os.environ.get("LD_LIBRARY_PATH"),
        "ld_preload":os.environ.get("LD_PRELOAD"),
        "umask":os.umask(0)}
(root/(sys.argv[1]+".json")).write_text(json.dumps(result))
if sys.argv[1]=="eb":sys.exit(int(os.environ.get("CONTROL_EB_STATUS","0")))
'''


def write_config(path, nodes, extra=""):
    """A site configuration naming NODES as the node-local root, owned by the caller."""
    path.write_text(
        "# test site\n"
        f"node_local_root = {nodes}\n"
        "node_local_fstype = xfs\n"
        f"shared_scratch = /scratch /work {nodes.parent / 'shared'}\n"
        "allocation_hint = salloc -n 16 -t 02:00:00\n" + extra
    )
    path.chmod(0o600)


class StorageFixture(unittest.TestCase):
    """The fixture, without tests; test_commands builds on it too."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-storage-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.nodes = self.root / "node-mounts"
        self.job = self.nodes / (pwd.getpwuid(os.getuid()).pw_name + ".123")
        self.job.mkdir(parents=True)
        self.prefix = self.root / "durable" / "owned prefix"
        self.script = self.root / "eb-local"
        original = SCRIPT.read_text()
        self.assertNotRegex(original, "/scratch-nod[e]")
        self.script.write_text(original)
        # The site configuration names the mount namespace; probes remain real.
        self.config = self.root / "site.conf"
        write_config(self.config, self.nodes)
        (self.root / "doubles.sh").write_text(DOUBLE)
        (self.root / "capture.py").write_text(CAPTURE)
        # EESSI_ARCH_GUARD=0 keeps a guard installed on the test host off the doubles.
        self.env = dict(os.environ, BASH_ENV=str(self.root / "doubles.sh"),
                        CONTROL_ROOT=str(self.root), CONTROL_JOB_ROOT=str(self.job),
                        CONTROL_PATH_NAMES=" ".join(MUTABLE + DURABLE),
                        EB_LOCAL_PREFIX=str(self.prefix), SLURM_JOB_ID="123",
                        TMPDIR=str(self.job), EB_LOCAL_CONFIG=str(self.config),
                        EESSI_ARCH_GUARD="0")
        for name in ("EESSI_USER_INSTALL", "EESSI_PROJECT_INSTALL",
                     "EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL"):
            self.env.pop(name, None)

    def run_wrapper(self, args=None, **extra):
        argv, env = binary.command(self.script, args or ["recipe.eb"], dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def refused(self, **extra):
        run = self.run_wrapper(**extra)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(self.prefix.exists())
        self.assertFalse((self.root / "load.json").exists())
        self.assertEqual(list(self.job.iterdir()), [])


class StorageControls(StorageFixture):
    def with_sbatch(self, **extra):
        bindir = self.root / "scheduler-bin"
        bindir.mkdir(exist_ok=True)
        sbatch = bindir / "sbatch"
        sbatch.write_text("#!/bin/sh\nexit 0\n")
        sbatch.chmod(0o755)
        return dict(PATH=f"{bindir}:{self.env.get('PATH', '/usr/bin:/bin')}", **extra)

    def test_workstation_build_uses_private_cache_workspace_and_removes_it(self):
        cache = self.root / "cache"
        self.config.write_text("# workstation: no node-local root\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR="", XDG_CACHE_HOME=str(cache),
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        work_root = cache / "eb-local" / "work"
        for name in MUTABLE:
            self.assertTrue(Path(built["paths"][name]).is_relative_to(work_root))
        self.assertEqual(work_root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(work_root.iterdir()), [])
        registry = self.prefix / ".eb-local" / f"workspace-roots-{os.getuid()}"
        self.assertEqual(list(registry.iterdir()), [])
        for name in DURABLE:
            self.assertTrue(Path(built["paths"][name]).is_relative_to(self.prefix))

    def test_explicit_local_mode_works_even_with_slurm_storage_configured(self):
        cache = self.root / "cache"
        local_config = self.root / "local.toml"
        local_config.write_text(
            '[storage]\nmode = "local"\n'
            f'node_local_root = "{self.nodes}"\n'
        )
        local_config.chmod(0o600)
        run = self.run_wrapper(
            EB_LOCAL_CONFIG=str(local_config), TMPDIR="",
            XDG_CACHE_HOME=str(cache),
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        self.assertTrue(
            Path(built["paths"]["EASYBUILD_BUILDPATH"]).is_relative_to(
                cache / "eb-local" / "work"
            )
        )

    def test_workstation_workspace_refuses_network_storage(self):
        cache = self.root / "cache"
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR="", XDG_CACHE_HOME=str(cache),
            CONTROL_JOB_ROOT=str(cache), CONTROL_FSTYPE="nfs",
        )
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("network or shared storage", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())

    def test_doctor_refuses_the_same_network_workstation_storage(self):
        cache = self.root / "cache"
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            ["doctor"], SLURM_JOB_ID="", TMPDIR="",
            XDG_CACHE_HOME=str(cache), CONTROL_JOB_ROOT=str(cache),
            CONTROL_FSTYPE="nfs",
        )
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("network or shared storage", run.stdout + run.stderr)

    def test_tmpdir_foreign_owned_workspace_parent_is_refused(self):
        tmpdir = self.root / "tmp"
        tmpdir.mkdir()
        fake_uid = os.getuid() + 1
        (tmpdir / f"eb-local-{fake_uid}").mkdir()
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR=str(tmpdir),
            EB_LOCAL_TEST_UID=str(fake_uid),
            EB_LOCAL_TEST_TMPDIR_UID=str(fake_uid),
        )
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("directory you own", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())

    def test_unsafe_tmpdir_bases_fall_back_to_the_private_cache(self):
        cache = self.root / "cache"
        self.config.write_text("# workstation\n")
        cases = {}
        nonsticky = self.root / "nonsticky-tmp"
        nonsticky.mkdir()
        nonsticky.chmod(0o777)
        cases["non-sticky writable"] = (nonsticky, {})
        foreign = self.root / "foreign-tmp"
        foreign.mkdir()
        cases["foreign-owned"] = (
            foreign,
            {"EB_LOCAL_TEST_TMPDIR_UID": str(os.getuid() + 1)},
        )
        for name, (tmpdir, extra) in cases.items():
            with self.subTest(name=name):
                (self.root / "eb.json").unlink(missing_ok=True)
                run = self.run_wrapper(
                    SLURM_JOB_ID="", TMPDIR=str(tmpdir),
                    XDG_CACHE_HOME=str(cache), **extra,
                )
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                built = json.loads((self.root / "eb.json").read_text())
                self.assertTrue(
                    Path(built["paths"]["EASYBUILD_BUILDPATH"]).is_relative_to(
                        cache / "eb-local" / "work"
                    )
                )

    def test_sticky_world_writable_tmpdir_is_accepted(self):
        tmpdir = self.root / "sticky-tmp"
        tmpdir.mkdir()
        tmpdir.chmod(0o1777)
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR=str(tmpdir),
            XDG_CACHE_HOME=str(self.root / "cache"),
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        self.assertTrue(
            Path(built["paths"]["EASYBUILD_BUILDPATH"]).is_relative_to(
                tmpdir / f"eb-local-{os.getuid()}" / "work"
            )
        )

    def test_tmpdir_world_writable_workspace_parent_is_refused(self):
        tmpdir = self.root / "tmp"
        parent = tmpdir / f"eb-local-{os.getuid()}"
        parent.mkdir(parents=True)
        parent.chmod(0o777)
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(SLURM_JOB_ID="", TMPDIR=str(tmpdir))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("must not be writable by group or others", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())

    def test_tmpdir_symlinked_workspace_parent_is_refused(self):
        tmpdir = self.root / "tmp"
        target = self.root / "target"
        tmpdir.mkdir()
        target.mkdir()
        (tmpdir / f"eb-local-{os.getuid()}").symlink_to(
            target, target_is_directory=True,
        )
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(SLURM_JOB_ID="", TMPDIR=str(tmpdir))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("symbolic link", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())

    def test_xdg_world_writable_workspace_parent_is_refused(self):
        cache = self.root / "cache"
        parent = cache / "eb-local"
        parent.mkdir(parents=True)
        parent.chmod(0o777)
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR="", XDG_CACHE_HOME=str(cache),
        )
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("must not be writable by group or others", run.stderr)
        self.assertFalse((self.root / "eb.json").exists())

    def test_workstation_ignores_tmpdir_on_tmpfs(self):
        cache = self.root / "cache"
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", XDG_CACHE_HOME=str(cache),
            CONTROL_FSTYPE="tmpfs",
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        self.assertTrue(
            Path(built["paths"]["EASYBUILD_BUILDPATH"]).is_relative_to(
                cache / "eb-local" / "work"
            )
        )

    def test_explain_without_node_local_root_has_no_empty_mount_path(self):
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            ["--explain", "recipe.eb"], SLURM_JOB_ID="", TMPDIR="",
            XDG_CACHE_HOME=str(self.root / "cache"),
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("mount under ,", run.stdout)
        self.assertIn("workstation's local disk", run.stdout)

    def test_clean_workspaces_removes_a_failed_workstation_build(self):
        tmpdir = self.root / "first-tmp"
        tmpdir.mkdir()
        self.config.write_text("# workstation\n")
        failed = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR=str(tmpdir),
            XDG_CACHE_HOME=str(self.root / "cache"),
            CONTROL_EB_STATUS="37",
        )
        self.assertEqual(failed.returncode, 37, failed.stdout + failed.stderr)
        work_root = tmpdir / f"eb-local-{os.getuid()}" / "work"
        self.assertEqual(len(list(work_root.glob("eb-local.*"))), 1)
        cleaned = self.run_wrapper(
            ["clean", "--delete", "--workspaces", "--no-logs"],
            SLURM_JOB_ID="", TMPDIR="",
            XDG_CACHE_HOME=str(self.root / "different-cache"),
        )
        self.assertEqual(cleaned.returncode, 0, cleaned.stdout + cleaned.stderr)
        self.assertEqual(list(work_root.iterdir()), [])
        registry = self.prefix / ".eb-local" / f"workspace-roots-{os.getuid()}"
        self.assertEqual(list(registry.iterdir()), [])

    def test_clean_workspaces_forgets_a_missing_recorded_root(self):
        tmpdir = self.root / "vanishing-tmp"
        tmpdir.mkdir()
        self.config.write_text("# workstation\n")
        failed = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR=str(tmpdir),
            XDG_CACHE_HOME=str(self.root / "cache"),
            CONTROL_EB_STATUS="37",
        )
        self.assertEqual(failed.returncode, 37, failed.stdout + failed.stderr)
        registry = self.prefix / ".eb-local" / f"workspace-roots-{os.getuid()}"
        self.assertEqual(len(list(registry.iterdir())), 1)
        shutil.rmtree(tmpdir)
        dry_run = self.run_wrapper(
            ["clean", "--dry-run", "--workspaces", "--no-logs"],
            SLURM_JOB_ID="", TMPDIR="",
            XDG_CACHE_HOME=str(self.root / "different-cache"),
        )
        self.assertEqual(
            dry_run.returncode, 0, dry_run.stdout + dry_run.stderr,
        )
        self.assertEqual(len(list(registry.iterdir())), 1)
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                cleaned = self.run_wrapper(
                    ["clean", "--delete", "--workspaces", "--no-logs"],
                    SLURM_JOB_ID="", TMPDIR="",
                    XDG_CACHE_HOME=str(self.root / "different-cache"),
                )
                self.assertEqual(
                    cleaned.returncode, 0, cleaned.stdout + cleaned.stderr,
                )
                self.assertEqual(list(registry.iterdir()), [])

    def test_clean_workspaces_refuses_an_unreadable_recorded_root(self):
        tmpdir = self.root / "sealed-tmp"
        tmpdir.mkdir()
        self.config.write_text("# workstation\n")
        failed = self.run_wrapper(
            SLURM_JOB_ID="", TMPDIR=str(tmpdir),
            XDG_CACHE_HOME=str(self.root / "cache"),
            CONTROL_EB_STATUS="37",
        )
        self.assertEqual(failed.returncode, 37, failed.stdout + failed.stderr)
        work_root = tmpdir / f"eb-local-{os.getuid()}" / "work"
        work_root.chmod(0)
        self.addCleanup(lambda: work_root.chmod(0o700))
        cleaned = self.run_wrapper(
            ["clean", "--delete", "--workspaces", "--no-logs"],
            SLURM_JOB_ID="", TMPDIR="",
            XDG_CACHE_HOME=str(self.root / "different-cache"),
        )
        self.assertEqual(cleaned.returncode, 2, cleaned.stdout + cleaned.stderr)
        self.assertIn(f"cannot read {work_root}", cleaned.stderr)

    def test_doctor_reports_insecure_workspace_parents_and_continues(self):
        self.config.write_text("# workstation\n")
        cases = {}
        foreign_tmp = self.root / "doctor-foreign"
        fake_uid = os.getuid() + 1
        (foreign_tmp / f"eb-local-{fake_uid}").mkdir(parents=True)
        cases["directory you own"] = (
            foreign_tmp,
            {
                "EB_LOCAL_TEST_UID": str(fake_uid),
                "EB_LOCAL_TEST_TMPDIR_UID": str(fake_uid),
            },
        )
        writable_tmp = self.root / "doctor-writable"
        writable_parent = writable_tmp / f"eb-local-{os.getuid()}"
        writable_parent.mkdir(parents=True)
        writable_parent.chmod(0o777)
        cases["must not be writable by group or others"] = (writable_tmp, {})
        symlink_tmp = self.root / "doctor-symlink"
        symlink_tmp.mkdir()
        symlink_target = self.root / "doctor-target"
        symlink_target.mkdir()
        (symlink_tmp / f"eb-local-{os.getuid()}").symlink_to(
            symlink_target, target_is_directory=True,
        )
        cases["symbolic link"] = (symlink_tmp, {})
        for reason, (tmpdir, extra) in cases.items():
            with self.subTest(reason=reason):
                run = self.run_wrapper(
                    ["doctor"], SLURM_JOB_ID="", TMPDIR=str(tmpdir),
                    XDG_CACHE_HOME=str(self.root / "cache"), **extra,
                )
                self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                self.assertEqual(run.stderr, "")
                self.assertIn(f"FAIL workstation workspace parent", run.stdout)
                self.assertIn(reason, run.stdout)
                self.assertIn("EESSI is not loaded in this shell", run.stdout)
                self.assertTrue(
                    run.stdout.rstrip().endswith(
                        "Something above says FAIL; builds stop there."
                    )
                )

    def test_cluster_refusal_hint_preserves_global_configuration_options(self):
        options = self.root / "hint options.toml"
        options.write_text(
            '[profile.hint]\nprefix = "/unused/profile-prefix"\n'
        )
        options.chmod(0o600)
        project = self.root / "project install"
        run = self.run_wrapper(
            [
                "--config", str(options), "--profile", "hint",
                "--project", str(project), "recipe with spaces.eb", "--robot",
            ],
            SLURM_JOB_ID="", **self.with_sbatch(),
        )
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn(
            "  opt in to this machine's local disk with: "
            f"eb-local --config '{options}' --profile hint "
            f"--project '{project}' --workstation "
            "'recipe with spaces.eb' --robot\n",
            run.stderr,
        )

    def test_sbatch_without_an_allocation_preserves_the_cluster_refusal(self):
        run = self.run_wrapper(SLURM_JOB_ID="", **self.with_sbatch())
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("inside an allocation", run.stderr)
        self.assertFalse(self.prefix.exists())

    def test_nonempty_slurm_context_prevents_automatic_workstation_mode(self):
        self.config.write_text("# no site storage\n")
        run = self.run_wrapper(
            SLURM_JOB_ID="", SLURM_CLUSTER_NAME="cluster",
            TMPDIR="", XDG_CACHE_HOME=str(self.root / "cache"),
        )
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("storage.node_local_root", run.stderr)
        self.assertIn("--workstation", run.stderr)

    def test_workstation_option_forces_local_mode_with_sbatch(self):
        self.config.write_text("# no site storage\n")
        for args in (
            ["--workstation", "recipe.eb"],
            ["recipe.eb", "--workstation"],
        ):
            with self.subTest(args=args):
                run = self.run_wrapper(
                    args, SLURM_JOB_ID="", TMPDIR="",
                    XDG_CACHE_HOME=str(self.root / "cache"),
                    **self.with_sbatch(),
                )
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_doctor_reports_workstation_capacity(self):
        self.config.write_text("# workstation\n")
        run = self.run_wrapper(
            ["doctor"], SLURM_JOB_ID="", TMPDIR="",
            XDG_CACHE_HOME=str(self.root / "cache"),
            EB_LOCAL_TEST_WORKSPACE_CAPACITY="8192:17",
        )
        self.assertIn("8192 free bytes, 17 free inodes", run.stdout)

    def test_invalid_allocation_identity_creates_no_prefix(self):
        self.refused(SLURM_JOB_ID="not-a-job")

    def test_shared_tmpdir_is_refused_before_prefix_creation(self):
        other = self.nodes / "other-job.123"
        self.job.rename(other)
        self.job = other
        self.env["CONTROL_JOB_ROOT"] = str(other)
        self.refused(TMPDIR=str(self.root))

    def test_gpfs_mount_is_refused(self):
        self.refused(CONTROL_FSTYPE="gpfs")

    def test_tmpfs_mount_is_refused(self):
        self.refused(CONTROL_FSTYPE="tmpfs")

    def test_foreign_mount_owner_is_refused(self):
        self.refused(CONTROL_OWNER=str(os.getuid() + 1))

    def test_enclosing_mount_is_refused(self):
        self.refused(CONTROL_MOUNT_TARGET=str(self.nodes))

    def test_read_only_mount_is_refused(self):
        self.refused(CONTROL_MOUNT_OPTIONS="ro,relatime")

    def test_symlink_root_is_refused(self):
        real = self.root / "real-job"
        self.job.rename(real)
        self.job.symlink_to(real, target_is_directory=True)
        self.refused(TMPDIR=str(self.job))

    def test_parent_symlink_escape_is_refused(self):
        real = self.root / "real-node-mounts"
        self.nodes.rename(real)
        self.nodes.symlink_to(real, target_is_directory=True)
        self.refused(TMPDIR=str(self.job))

    @unittest.skipUnless(binary.ZIG, "dropping BASH_ENV and loader paths is a feature of the Zig build")
    def test_build_drops_bash_env_and_loader_paths(self):
        marker = self.root / "bash-env-ran"
        evil = self.root / "evil-bash-env.sh"
        evil.write_text(f"touch {marker}\n")
        argv, env = binary.command(self.script, ["recipe.eb"], dict(
            self.env, LD_LIBRARY_PATH="/host/lib", LD_PRELOAD="/host/hack.so", SHELLOPTS="xtrace"))
        # Put back after the doubles have been handed to the test prelude.
        env["BASH_ENV"] = str(evil)
        run = subprocess.run(argv, env=env, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse(marker.exists(), run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        self.assertIsNone(built["ld_library_path"])
        self.assertIsNone(built["ld_preload"])
        self.assertNotIn("+ export", run.stderr)
        self.assertIn("LD_LIBRARY_PATH", run.stderr)

    def test_build_paths_survive_unload_and_module_initialization(self):
        args = ["recipe with spaces.eb", "--hooks=/selected/custom.py", "--robot"]
        # Kept, so the paths the build used can be inspected afterwards.
        run = self.run_wrapper(args, EB_LOCAL_KEEP_WORK="1")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        loaded = json.loads((self.root / "load.json").read_text())
        built = json.loads((self.root / "eb.json").read_text())
        for event in (loaded, built):
            for name in MUTABLE:
                path = Path(event["paths"][name])
                self.assertTrue(path.is_relative_to(self.job), (name, path))
                self.assertTrue(path.is_dir(), (name, path))
            for name in DURABLE:
                path = Path(event["paths"][name])
                self.assertTrue(path.is_relative_to(self.prefix))
                self.assertFalse(path.is_relative_to(self.job))
                self.assertTrue(path.is_dir())
        self.assertEqual(loaded["paths"], built["paths"])
        self.assertEqual(built["argv"], args)
        self.assertEqual(built["user"], str(self.prefix))
        self.assertEqual(built["hooks"], "/selected/hooks.py")

    def test_a_project_build_keeps_the_project_umask(self):
        # EESSI-extend gives a project install umask 002, so that a second
        # member's build can write the sources, logs, locks and module
        # directories the first one made.
        self.prefix.mkdir(parents=True)
        self.prefix.chmod(0o2770)
        argv, env = binary.command(self.script, ["--project", str(self.prefix), "recipe.eb"], dict(self.env))
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True, umask=0o022)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        built = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(built["project"], str(self.prefix))
        self.assertEqual(built["argv"], ["recipe.eb"])
        self.assertEqual(built["umask"], 0o002)
        for name in DURABLE:
            self.assertEqual(Path(built["paths"][name]).stat().st_mode & 0o070, 0o070, name)

    def test_build_failure_status_is_retained(self):
        run = self.run_wrapper(CONTROL_EB_STATUS="37")
        self.assertEqual(run.returncode, 37, run.stdout + run.stderr)

    def test_help_is_pure_without_allocation(self):
        run = self.run_wrapper(["--help"], SLURM_JOB_ID="", TMPDIR="")
        self.assertEqual(run.returncode, 0)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(list(self.job.iterdir()), [])

    def test_environment_mode_is_pure_without_allocation(self):
        run = self.run_wrapper(["--env"], SLURM_JOB_ID="", TMPDIR="")
        self.assertEqual(run.returncode, 0)
        self.assertIn("EESSI_USER_INSTALL=", run.stdout)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(list(self.job.iterdir()), [])


    def test_alias_inside_mount_namespace_cannot_escape_to_another_directory(self):
        other = self.nodes / "other-allocation"
        self.job.rename(other)
        self.job.symlink_to(other, target_is_directory=True)
        self.refused(TMPDIR=str(self.job))

    def test_durable_sources_cannot_be_redirected_into_job_storage(self):
        (self.prefix / ".eb-local").mkdir(parents=True)
        (self.prefix / ".eb-local" / "sources").symlink_to(self.job, target_is_directory=True)
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse((self.root / "load.json").exists())
        self.assertEqual(list(self.job.iterdir()), [])

    def test_dangling_symlink_into_shared_scratch_is_refused_before_a_workspace(self):
        # The target does not exist yet. Resolving only links whose target
        # exists would accept the path, then make the directory through the
        # link once someone creates the target.
        self.prefix.mkdir(parents=True)
        (self.prefix / ".eb-local").symlink_to("/scratch/not-created-yet")
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("durable prefix", run.stderr)
        self.assertFalse((self.root / "load.json").exists())
        self.assertEqual(list(self.job.iterdir()), [])
        self.assertFalse(Path("/scratch/not-created-yet").exists())

    def test_missing_configuration_refuses_before_any_write(self):
        self.config.unlink()
        self.refused()

    def test_configuration_without_node_local_root_selects_local_mode(self):
        self.config.write_text("node_local_fstype = xfs\n")
        run = self.run_wrapper(SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue((self.root / "eb.json").exists())
        built = json.loads((self.root / "eb.json").read_text())
        self.assertTrue(
            Path(built["paths"]["EASYBUILD_BUILDPATH"]).is_relative_to(
                self.job / f"eb-local-{os.getuid()}" / "work"
            )
        )

    def test_group_writable_configuration_is_refused(self):
        self.config.chmod(0o620)
        self.refused()

    def test_symlinked_configuration_is_refused(self):
        real = self.root / "real.conf"
        self.config.rename(real)
        self.config.symlink_to(real)
        self.refused()

    def test_unknown_setting_is_refused(self):
        write_config(self.config, self.nodes, "source_me = $(touch injected)\n")
        self.refused()
        self.assertFalse((self.root / "injected").exists())

    def test_configured_shared_scratch_is_refused_as_prefix(self):
        destination = self.root / "shared" / "install"
        run = self.run_wrapper(EB_LOCAL_PREFIX=str(destination))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(destination.exists())

    def test_shared_scratch_metacharacters_are_literal(self):
        # scratch[a] is a character class to the shell. A neighbour named
        # scratcha must not become the refused path in its place.
        scratch = self.root / "scratch[a]"
        (self.root / "scratcha").mkdir()
        self.config.write_text(
            f"node_local_root = {self.nodes}\n"
            "node_local_fstype = xfs\n"
            f"shared_scratch = {scratch}\n"
        )
        self.config.chmod(0o600)
        destination = scratch / "install"
        run = self.run_wrapper(EB_LOCAL_PREFIX=str(destination))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(destination.exists())

    def test_configured_fstype_is_enforced(self):
        write_config(self.config, self.nodes, "node_local_fstype = ext4\n")
        self.refused()

    def test_configured_mount_name_names_the_allocation_mount(self):
        mount = self.nodes / "job-123"
        self.job.rename(mount)
        self.job = mount
        self.env.update(CONTROL_JOB_ROOT=str(mount), TMPDIR=str(mount))
        write_config(self.config, self.nodes, "node_local_mount = job-%j\n")
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        paths = json.loads((self.root / "eb.json").read_text())["paths"]
        self.assertTrue(Path(paths["TMPDIR"]).is_relative_to(mount))
        self.assertTrue(Path(paths["WORKING_DIR"]).is_relative_to(mount))

    def test_the_default_mount_is_not_used_when_the_site_names_another(self):
        write_config(self.config, self.nodes, "node_local_mount = job-%j\n")
        self.refused()

    def test_mount_name_that_is_not_one_file_name_with_the_job_id_is_refused(self):
        for pattern in ("%u", "u.123", "../%j", "x/%j", "%x%j", "%j;id"):
            with self.subTest(pattern=pattern):
                write_config(self.config, self.nodes, f"node_local_mount = {pattern}\n")
                run = self.run_wrapper()
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertIn("node_local_mount must be one file name", run.stderr)
                self.assertFalse(self.prefix.exists())
                self.assertEqual(list(self.job.iterdir()), [])

    def test_allocation_hint_comes_from_the_configuration(self):
        run = self.run_wrapper(SLURM_JOB_ID="", **self.with_sbatch())
        self.assertEqual(run.returncode, 2)
        self.assertIn("salloc -n 16 -t 02:00:00", run.stderr)

    def test_install_prefix_cannot_use_job_storage(self):
        destination = self.job / "install"
        run = self.run_wrapper(EB_LOCAL_PREFIX=str(destination))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.job.iterdir()), [])


@unittest.skipUnless(binary.ZIG, "the wording of these refusals is the Zig build's")
class RefusalWording(StorageFixture):
    """A refusal says what it refused and why, and what was not done; its next
    line says what to change: a setting, with its value and where it was set,
    a variable, or a command."""

    def refusal(self, args=None, **extra):
        run = self.run_wrapper(args, **extra)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        return run.stderr.splitlines()

    def site(self, line):
        return f"[site {self.config}:{line}]"

    def test_a_mount_another_user_owns(self):
        first, fix = self.refusal(CONTROL_OWNER=str(os.getuid() + 1))
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} belongs to uid {os.getuid()}, "
                                f"not to you (uid {os.getuid() + 1}); nothing was built.")
        self.assertEqual(fix, f"  storage.node_local_mount, %u.%j [default], names your job's own mount below "
                              f"storage.node_local_root, {self.nodes} {self.site(2)}, with %u for your user name and %j "
                              "for the job id; set them in the site file to where Slurm mounts your job's node-local disk.")

    def test_a_mount_on_another_file_system(self):
        first, fix = self.refusal(CONTROL_FSTYPE="tmpfs")
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is on tmpfs, not xfs; nothing was built.")
        self.assertIn("not shared or memory-backed storage", fix)
        self.assertIn(f"storage.node_local_fstype, xfs {self.site(3)}, names the nodes' file system", fix)

    def test_a_mount_that_is_part_of_another_or_read_only(self):
        first, fix = self.refusal(CONTROL_MOUNT_TARGET=str(self.nodes))
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is not a mount of its own but part of "
                                f"{self.nodes}; nothing was built.")
        self.assertTrue(fix.endswith(f"storage.node_local_root, {self.nodes} {self.site(2)}, and storage.node_local_mount, "
                                     "%u.%j [default], name it; build in an allocation that has a node-local disk, or set them "
                                     "in the site file to where Slurm mounts your job's node-local disk."), fix)
        first, fix = self.refusal(CONTROL_MOUNT_OPTIONS="ro,relatime")
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is not mounted read-write (ro,relatime); "
                                "nothing was built.")

    def test_a_mount_the_site_file_names_that_does_not_exist(self):
        write_config(self.config, self.nodes, "node_local_mount = job-%j\n")
        first, fix = self.refusal()
        self.assertEqual(first, f"eb-local: the node-local mount {self.nodes}/job-123 does not exist; nothing was built.")
        self.assertIn(f"storage.node_local_mount, job-%j {self.site(6)}, name it", fix)

    def test_a_mount_reached_through_a_link_names_the_directory_itself(self):
        real = self.root / "real-node-mounts"
        self.nodes.rename(real)
        self.nodes.symlink_to(real, target_is_directory=True)
        first, fix = self.refusal()
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is reached through a symbolic link, "
                                f"as {real / self.job.name}; nothing was built.")
        self.assertTrue(fix.endswith(f"set storage.node_local_root, {self.nodes} {self.site(2)}, in the site file "
                                     f"to the directory itself, {real}."), fix)

    def test_no_job_a_job_id_that_is_not_one_and_no_node_local_root(self):
        self.assertEqual(self.refusal(SLURM_JOB_ID="", SLURM_CLUSTER_NAME="cluster")[0],
                         "eb-local: not inside a Slurm job: SLURM_JOB_ID is unset or empty; nothing was built.")
        first, fix = self.refusal(SLURM_JOB_ID="not-a-job")
        self.assertEqual(first, "eb-local: SLURM_JOB_ID=not-a-job is not a Slurm job id; nothing was built.")
        self.assertIn("run eb-local inside the allocation, from salloc, srun or sbatch", fix)
        self.config.write_text("node_local_fstype = xfs\n")
        first, fix = self.refusal()
        self.assertEqual(first, "eb-local: no site file sets storage.node_local_root, the directory that holds each "
                                "job's node-local mount; nothing was built.")
        self.assertIn("--config FILE or EB_LOCAL_CONFIG=FILE", fix)
        self.assertIn("--workstation", fix)

    def test_a_prefix_on_shared_scratch_or_in_job_storage_names_where_each_was_set(self):
        for prefix, tree, what in (
                (self.root / "shared" / "install", self.root / "shared",
                 f"shared scratch in storage.shared_scratch {self.site(4)}"),
                (self.job / "install", self.nodes, f"node-local storage below storage.node_local_root {self.site(2)}")):
            with self.subTest(prefix=prefix):
                first, fix = self.refusal(EB_LOCAL_PREFIX=str(prefix))
                self.assertEqual(first, f"eb-local: the install prefix {prefix} [environment EB_LOCAL_PREFIX] is under "
                                        f"{tree}, {what}; nothing was built.")
                self.assertEqual(fix, "  Installs, sources and logs must outlive the job and not be on shared scratch; "
                                      "set a prefix on durable storage you own with prefix in your eb-local configuration, "
                                      "EB_LOCAL_PREFIX, or --project DIR for a project.")
                self.assertFalse(prefix.exists())

    def test_a_link_that_leads_sources_or_versions_away(self):
        (self.prefix / ".eb-local").mkdir(parents=True)
        sources = self.prefix / ".eb-local" / "sources"
        sources.symlink_to(self.job, target_is_directory=True)
        first, fix = self.refusal()
        self.assertEqual(first, f"eb-local: {sources} leads to {self.job}, not to a directory inside the install "
                                f"prefix {self.prefix}; nothing was built.")
        self.assertIn(f"Sources and logs stay in the durable prefix, beside the installs: replace the symbolic link "
                      f"in {sources} with a directory, or set a prefix", fix)
        self.assertEqual(self.refusal(["--explain", "recipe.eb"])[0], first.replace("nothing was built", "a build would stop here"))
        self.assertEqual(self.refusal(["clean"])[0], first.replace("nothing was built", "nothing was removed"))
        sources.unlink()
        shared = self.root / "shared" / "versions"
        (self.prefix / "versions").symlink_to(shared, target_is_directory=True)
        first, fix = self.refusal()
        self.assertEqual(first, f"eb-local: {self.prefix}/versions leads to {shared}, under {shared.parent}, shared "
                                f"scratch in storage.shared_scratch {self.site(4)}; nothing was built.")
        self.assertIn(f"replace the symbolic link in {self.prefix}/versions with a directory", fix)
        self.assertEqual(list(self.job.iterdir()), [])

    def test_mount_symlink_non_directory_and_absent_mountinfo_refusals(self):
        real_job = self.root / "real-job"
        real_job.mkdir()
        self.job.rmdir()
        self.job.symlink_to(real_job, target_is_directory=True)
        first, fix = self.refusal()
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is a symbolic link; nothing was built.")
        self.assertIn("build in an allocation whose node-local mount is a directory of its own", fix)

        self.job.unlink()
        self.job.write_text("not a directory\n", encoding="utf-8")
        first, fix = self.refusal()
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is not a directory; nothing was built.")
        self.assertIn("node_local_root", fix)

        self.job.unlink()
        self.job.mkdir()
        empty_mountinfo = self.root / "empty-mountinfo"
        empty_mountinfo.write_text("", encoding="utf-8")
        first, fix = self.refusal(CONTROL_JOB_ROOT="", EB_LOCAL_TEST_MOUNTINFO=str(empty_mountinfo))
        self.assertEqual(first, f"eb-local: no mount in /proc/self/mountinfo holds the node-local mount {self.job}; nothing was built.")
        self.assertIn("where /proc is mounted", fix)

    def test_clean_workspaces_says_nothing_was_removed(self):
        first, fix = self.refusal(["clean", "--workspaces"], CONTROL_FSTYPE="tmpfs")
        self.assertEqual(first, f"eb-local: the node-local mount {self.job} is on tmpfs, not xfs; nothing was removed.")


@unittest.skipUnless(binary.ZIG, "checking where EESSI-extend installs is a feature of the Zig build")
class InstallPathChecks(StorageFixture):
    """The install path EESSI-extend chose, and install variables left in the shell or set as it loads."""

    def test_an_install_path_moved_out_of_the_prefix_stops_the_build(self):
        for moved in ("/elsewhere/hooktree", f"{self.prefix}/versions/../../elsewhere",
                      f"{self.prefix}-old/versions/2026.06", f"{self.prefix}/versions"):
            with self.subTest(moved=moved):
                run = self.run_wrapper(CONTROL_INSTALLPATH=moved)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertFalse((self.root / "eb.json").exists())
                self.assertNotIn("installing into", run.stdout)
                self.assertIn(f"eb-local: loading EESSI-extend/2026.06-easybuild set the install path to {moved}, "
                              f"outside {self.prefix}/versions, the tree eb-local checked; nothing was built.", run.stderr)

    def test_a_load_that_sets_an_install_path_for_modules_stops_the_build(self):
        run = self.run_wrapper(CONTROL_LOAD_SETS="EASYBUILD_INSTALLPATH_MODULES=/elsewhere/modules")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse((self.root / "eb.json").exists())
        self.assertIn("eb-local: loading EESSI-extend/2026.06-easybuild set EASYBUILD_INSTALLPATH_MODULES=/elsewhere/modules, "
                      f"which would put part of the install outside {self.prefix}/versions", run.stderr)

    def test_an_install_variable_set_as_the_module_loads_is_reported_and_does_not_move_the_build(self):
        run = self.run_wrapper(CONTROL_LOAD_SETS="EESSI_PROJECT_INSTALL=/projects/a")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads((self.root / "eb.json").read_text())["user"], str(self.prefix))
        self.assertIn("eb-local: loading EESSI-extend/2026.06-easybuild set EESSI_PROJECT_INSTALL=/projects/a; "
                      f"this build still installs into {self.prefix}, but a shell that loads EESSI-extend by hand "
                      "keeps the change, and its next load installs elsewhere.", run.stderr)

    def test_a_leftover_install_variable_is_cleared_and_reported(self):
        run = self.run_wrapper(EESSI_USER_INSTALL="/home/alice/eessi-old",
                               EASYBUILD_INSTALLPATH_MODULES="/home/alice/modules")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads((self.root / "eb.json").read_text())["user"], str(self.prefix))
        self.assertIn("eb-local: EESSI_USER_INSTALL=/home/alice/eessi-old is set in this shell; this build clears it, "
                      "but EESSI-extend or eb run by hand would use it", run.stderr)
        self.assertIn("eb-local: EASYBUILD_INSTALLPATH_MODULES=/home/alice/modules is set in this shell", run.stderr)

    def test_what_eb_local_env_sets_for_this_prefix_is_not_a_leftover(self):
        run = self.run_wrapper(EESSI_USER_INSTALL=str(self.prefix), EASYBUILD_PREFIX="/tmp/alice/easybuild",
                               EASYBUILD_INSTALLPATH=f"{self.prefix}/versions/2026.06/software/linux/x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("is set in this shell", run.stderr)


@unittest.skipUnless(binary.ZIG, "clean removal edge cases target the Zig build")
class CleanFilesystemEdgeCases(StorageFixture):
    def test_clean_removes_readonly_reprod_and_workspace_trees_with_spaces(self):
        logs = self.prefix / ".eb-local" / "logs"
        reprod = logs / "reprod_1"
        sub = reprod / "ro sub"
        sub.mkdir(parents=True)
        ro_file = sub / "recipe.eb"
        ro_file.write_text("easyblock = 'ConfigureMake'\n")
        ro_file.chmod(0o444)
        sub.chmod(0o555)
        reprod.chmod(0o555)
        old = time.time() - 40 * 86400
        os.utime(ro_file, (old, old))
        os.utime(sub, (old, old))
        os.utime(reprod, (old, old))

        ws = self.job / "eb-local.AbCd1234"
        ws_ro = ws / "go pkg"
        ws_ro.mkdir(parents=True)
        ws_file = ws_ro / "mod.txt"
        ws_file.write_text("cached\n")
        ws_file.chmod(0o444)
        ws_ro.chmod(0o555)

        argv, env = binary.command(
            self.script,
            ["clean", "--delete", "--workspaces"],
            dict(self.env),
        )
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        expected = (
            f"  {reprod}/\n"
            f"  {ws}/ (build workspace)\n"
            "eb-local: removed 1 build workspace(s)\n"
            "eb-local: deleted 1 item(s)\n"
        ).encode()
        self.assertEqual((run.returncode, run.stdout, run.stderr), (0, expected, b""))
        self.assertFalse(reprod.exists())
        self.assertFalse(ws.exists())

    def test_clean_reports_actual_count_and_exits_1_on_partial_delete_failure(self):
        sources = self.prefix / ".eb-local" / "sources"
        removable_dir = sources / "ok"
        locked_dir = sources / "locked"
        removable_dir.mkdir(parents=True)
        locked_dir.mkdir(parents=True)
        ok_file = removable_dir / "ok.tar.gz"
        bad_file = locked_dir / "bad.tar.gz"
        ok_file.write_text("ok\n")
        bad_file.write_text("locked\n")
        locked_dir.chmod(0o555)
        try:
            argv, env = binary.command(
                self.script,
                ["clean", "--delete", "--no-logs", "--sources"],
                dict(self.env, SLURM_JOB_ID=""),
            )
            run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
            self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
            self.assertIn(f"cannot remove {bad_file}", run.stderr)
            self.assertIn("eb-local: deleted 1 item(s)\n", run.stdout)
            self.assertNotIn("deleted 2 item(s)", run.stdout)
            self.assertFalse(ok_file.exists())
            self.assertTrue(bad_file.exists())
        finally:
            locked_dir.chmod(0o755)

    def test_clean_refuses_fifo_lockfile(self):
        eb_dir = self.prefix / ".eb-local"
        eb_dir.mkdir(parents=True, exist_ok=True)
        lock_file = eb_dir / ".lock"
        os.mkfifo(lock_file)
        argv, env = binary.command(
            self.script,
            ["clean", "--sources"],
            dict(self.env, SLURM_JOB_ID=""),
        )
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn("not a regular file", run.stderr)


if __name__ == "__main__":
    unittest.main()
