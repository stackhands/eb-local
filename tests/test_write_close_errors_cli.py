"""A failed close or fsync of a file eb-local writes is an error.

NFS and some quota setups report a lost write only when the file is closed
or synced. The test artifact reads EB_LOCAL_TEST_CLOSE_ERRNO and
EB_LOCAL_TEST_FSYNC_ERRNO, and the close or fsync of each written file then
fails with that errno. EB_LOCAL_TEST_CLOSE_AFTER and
EB_LOCAL_TEST_FSYNC_AFTER let that many calls succeed first, and
EB_LOCAL_TEST_CLOSE_COUNT and EB_LOCAL_TEST_FSYNC_COUNT let only that many
fail, so a restore after the failure can succeed. Each case runs
the command once without the errno, which must succeed, and once with it,
which must report the errno and must not say that the file was written.
"""
import json
import os
import re
import stat
import subprocess
import unittest

import binary
from test_lmod_cache import MODULE
from test_storage import StorageFixture

EIO_TEXT = "[Errno 5] Input/output error"
HOOKS = ("EB_LOCAL_TEST_FSYNC_ERRNO", "EB_LOCAL_TEST_CLOSE_ERRNO")
# EB_LOCAL_TEST_RECORD_OPEN_ERRNO fails the creation of the temporary file
# a workspace-root record is written to.
RECORD_HOOKS = (*HOOKS, "EB_LOCAL_TEST_RECORD_OPEN_ERRNO")


def count(hook):
    """The variable that limits how many calls `hook` fails."""
    return hook.replace("_ERRNO", "_COUNT")


@unittest.skipUnless(
    binary.ZIG and os.geteuid() != 0,
    "the close and fsync errno hooks are in the Zig test artifact",
)
class WriteCloseErrors(StorageFixture):
    def run_bin(self, args, *, cwd=None, **extra):
        argv, env = binary.command(self.script, args, {**self.env, **extra})
        return subprocess.run(argv, env=env, cwd=cwd or self.root, capture_output=True, text=True, check=False, timeout=120)

    def fresh_dir(self, name):
        path = self.root / name
        path.mkdir()
        return path

    def fake_eessi(self):
        repo = self.root / "fake-eessi"
        init_file = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_file.parent.mkdir(parents=True)
        init_file.write_text(
            "export EESSI_VERSION=2026.06\n"
            "export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4\n"
            "module() { export LOADEDMODULES=EESSI/2026.06:demo/1.0; }\n",
            encoding="utf-8",
        )
        return repo

    def test_dev_envrc_reports_a_failed_close_of_a_new_envrc(self):
        control = self.fresh_dir("envrc-control")
        ok = self.run_bin(["dev", "--envrc"], cwd=control, SLURM_JOB_ID="")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("wrote .envrc", ok.stderr)

        cwd = self.fresh_dir("envrc-close")
        got = self.run_bin(["dev", "--envrc"], cwd=cwd, SLURM_JOB_ID="", EB_LOCAL_TEST_CLOSE_ERRNO="EIO")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn(f"eb-local: cannot write .envrc ({EIO_TEXT})", got.stderr)
        self.assertNotIn("wrote .envrc", got.stderr)

    def test_dev_lock_reports_a_failed_close_of_a_new_lock_file(self):
        repo = self.fake_eessi()
        extra = {"SLURM_JOB_ID": "", "EESSI_CVMFS_REPO": str(repo), "BASH_ENV": ""}
        control = self.fresh_dir("lock-control")
        ok = self.run_bin(["dev", "--lock", "demo/1.0"], cwd=control, **extra)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertTrue((control / "eb-local.lock").is_file())

        cwd = self.fresh_dir("lock-close")
        got = self.run_bin(["dev", "--lock", "demo/1.0"], cwd=cwd, EB_LOCAL_TEST_CLOSE_ERRNO="EIO", **extra)
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn(f"eb-local: cannot write eb-local.lock ({EIO_TEXT})", got.stderr)

    def test_doctor_workspace_fails_the_probe_when_its_close_fails(self):
        ws = self.fresh_dir("probe-ws")
        ok = self.run_bin(["doctor", "--workspace", str(ws)], SLURM_JOB_ID="")
        self.assertIn("created, wrote, renamed, executed and removed a probe", ok.stdout)

        got = self.run_bin(["doctor", "--workspace", str(ws)], SLURM_JOB_ID="", EB_LOCAL_TEST_CLOSE_ERRNO="EIO")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn(f"workspace {ws} probe could not complete ({EIO_TEXT})", got.stdout)
        self.assertNotIn("created, wrote, renamed", got.stdout)
        self.assertEqual(list(ws.iterdir()), [])

    def workstation_build(self, **extra):
        self.config.write_text("# workstation: no node-local root\n")
        cache = self.root / "cache"
        argv, env = binary.command(
            self.script, ["recipe.eb"],
            {**self.env, "SLURM_JOB_ID": "", "TMPDIR": "", "XDG_CACHE_HOME": str(cache), **extra},
        )
        # A hook that retried EINTR would never return.
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True, check=False, timeout=120)

    def test_workstation_build_stops_when_the_workspace_root_record_is_not_durable(self):
        ok = self.workstation_build()
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        (self.root / "eb.json").unlink()
        work_root = self.root / "cache" / "eb-local" / "work"
        registry = self.prefix / ".eb-local" / f"workspace-roots-{os.getuid()}"

        for hook in RECORD_HOOKS:
            with self.subTest(hook=hook):
                got = self.workstation_build(**{hook: "EIO"})
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertIn(f"eb-local: cannot record workstation workspace root {work_root} ({EIO_TEXT})\n", got.stderr)
                self.assertFalse((self.root / "eb.json").exists())
                self.assertEqual(list(work_root.iterdir()), [])
                self.assertEqual(list(registry.iterdir()), [])

    def test_a_failed_record_write_keeps_the_record_of_older_workspaces(self):
        failed = self.workstation_build(CONTROL_EB_STATUS="37")
        self.assertEqual(failed.returncode, 37, failed.stdout + failed.stderr)
        work_root = self.root / "cache" / "eb-local" / "work"
        older = sorted(work_root.glob("eb-local.*"))
        self.assertEqual(len(older), 1)
        registry = self.prefix / ".eb-local" / f"workspace-roots-{os.getuid()}"
        [record] = registry.iterdir()
        kept = record.read_bytes()

        for hook in RECORD_HOOKS:
            with self.subTest(hook=hook):
                got = self.workstation_build(**{hook: "EIO"})
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertIn(f"eb-local: cannot record workstation workspace root {work_root} ({EIO_TEXT})\n", got.stderr)
                self.assertEqual(list(registry.iterdir()), [record])
                self.assertEqual(record.read_bytes(), kept)
                self.assertEqual(sorted(work_root.glob("eb-local.*")), older)
                listed = self.run_bin(
                    ["clean", "--dry-run", "--workspaces", "--no-logs", "--json"],
                    SLURM_JOB_ID="", TMPDIR="", XDG_CACHE_HOME=str(self.root / "different-cache"),
                )
                self.assertEqual(listed.returncode, 0, listed.stdout + listed.stderr)
                self.assertEqual(json.loads(listed.stdout)["workspaces"], [str(older[0])])

    def test_an_unusable_record_removes_the_workspace_of_the_build(self):
        failed = self.workstation_build(CONTROL_EB_STATUS="37")
        self.assertEqual(failed.returncode, 37, failed.stdout + failed.stderr)
        work_root = self.root / "cache" / "eb-local" / "work"
        older = sorted(work_root.glob("eb-local.*"))
        registry = self.prefix / ".eb-local" / f"workspace-roots-{os.getuid()}"
        [record] = registry.iterdir()
        record.chmod(0o644)

        got = self.workstation_build()
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn(
            f"eb-local: workstation workspace-root registry entry {record.name} must be a private regular file you own\n",
            got.stderr,
        )
        self.assertEqual(sorted(work_root.glob("eb-local.*")), older)
        self.assertEqual(list(registry.iterdir()), [record])

        moved = registry.with_name("moved-registry")
        registry.rename(moved)
        registry.symlink_to(moved)
        got = self.workstation_build()
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn(
            f"eb-local: workstation workspace parent {registry} is a symbolic link; "
            "the workspace-root registry was not opened.\n",
            got.stderr,
        )
        self.assertEqual(sorted(work_root.glob("eb-local.*")), older)

    def test_the_test_hooks_ignore_eintr(self):
        # A hook that let EINTR through would make `fsyncWritten` retry
        # until the timeout, so the close hook runs first.
        for hook in reversed(HOOKS):
            with self.subTest(hook=hook):
                got = self.workstation_build(**{hook: "EINTR"})
                self.assertEqual(got.returncode, 0, got.stdout + got.stderr)

    def write_spider(self, body):
        spider = self.root / "spider"
        spider.write_text(f"#!/bin/sh\nprintf '{body}\\n'\n", encoding="utf-8")
        spider.chmod(0o755)

    def lmod_cache(self, name, *, stamp=None, verify=False, **extra):
        modules = self.root / "modules"
        modules.mkdir(exist_ok=True)
        if not (self.root / "spider").exists():
            self.write_spider("spiderT = {}")
        cache = self.root / name
        stamp = stamp or self.root / f"{name}-stamp"
        args = [
            "lmod-cache",
            "--modulepath", str(modules),
            "--cache-dir", str(cache),
            "--timestamp", str(stamp),
            "--spider", str(self.root / "spider"),
        ]
        if verify:
            args.append("--verify")
        got = self.run_bin(args, **{"SLURM_JOB_ID": "", "PATH": "/usr/bin:/bin", **extra})
        return cache, stamp, got

    def assert_stamp_failed(self, got, stamp):
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn(f"eb-local: cannot write {stamp}: {EIO_TEXT}\n", got.stderr)
        self.assertNotIn("wrote ", got.stdout)
        leftovers = [p.name for p in stamp.parent.iterdir() if p.name.startswith(f".{stamp.name}.")]
        self.assertEqual(leftovers, [])

    def test_lmod_cache_fails_when_the_timestamp_directory_is_not_synced(self):
        _, _, ok = self.lmod_cache("control-cache")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("wrote ", ok.stdout)

        cache, stamp, got = self.lmod_cache("fsync-cache", EB_LOCAL_TEST_FSYNC_ERRNO="EIO")
        self.assert_stamp_failed(got, stamp)
        self.assertFalse((cache / "spiderT.lua").exists())

    def test_lmod_cache_fails_when_the_new_timestamp_is_not_closed(self):
        cache, stamp, got = self.lmod_cache("close-cache", EB_LOCAL_TEST_CLOSE_ERRNO="EIO")
        self.assert_stamp_failed(got, stamp)
        self.assertFalse((cache / "spiderT.lua").exists())
        self.assertFalse(stamp.exists())

    def assert_no_restore_temp(self, cache):
        self.assertEqual([p.name for p in cache.iterdir() if p.name.startswith(".spiderT.lua.")], [])

    def test_lmod_cache_puts_back_the_previous_cache_when_the_timestamp_fails(self):
        for hook in HOOKS:
            with self.subTest(hook=hook):
                name = f"prev-{hook.lower()}"
                self.write_spider("old-cache")
                cache, stamp, ok = self.lmod_cache(name)
                self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
                old_stamp = stamp.stat().st_mtime_ns

                self.write_spider("new-cache")
                _, _, got = self.lmod_cache(name, **{hook: "EIO", count(hook): "1"})
                self.assert_stamp_failed(got, stamp)
                self.assertNotIn("cannot restore", got.stderr)
                self.assertEqual((cache / "spiderT.lua").read_text(), "old-cache\n")
                self.assert_no_restore_temp(cache)
                if hook == "EB_LOCAL_TEST_CLOSE_ERRNO":
                    self.assertEqual(stamp.stat().st_mtime_ns, old_stamp)

    def test_lmod_cache_reports_a_previous_cache_it_cannot_put_back(self):
        for hook in HOOKS:
            with self.subTest(hook=hook):
                name = f"stuck-{hook.lower()}"
                self.write_spider("old-cache")
                cache, stamp, ok = self.lmod_cache(name)
                self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)

                self.write_spider("new-cache")
                _, _, got = self.lmod_cache(name, **{hook: "EIO"})
                self.assert_stamp_failed(got, stamp)
                first = f"eb-local: cannot write {stamp}: {EIO_TEXT}\n"
                restore = f"eb-local: cannot restore {cache / 'spiderT.lua'}: {EIO_TEXT}\n"
                self.assertIn(restore, got.stderr)
                self.assertLess(got.stderr.index(first), got.stderr.index(restore))
                self.assertEqual((cache / "spiderT.lua").read_text(), "new-cache\n")
                self.assert_no_restore_temp(cache)

    def assert_previous_cache_refused(self, got, cache, stamp, old_stamp):
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertNotIn("wrote ", got.stdout)
        self.assertEqual(stamp.stat().st_mtime_ns, old_stamp)
        self.assert_no_restore_temp(cache)
        self.assertEqual(sorted(p.name for p in cache.iterdir()), ["spiderT.lua"])

    def test_lmod_cache_does_not_replace_a_previous_cache_it_cannot_read(self):
        # Without its bytes the previous cache could not be put back, so
        # it is not replaced.
        self.write_spider("old-cache")
        cache, stamp, ok = self.lmod_cache("unreadable")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        old_stamp = stamp.stat().st_mtime_ns
        previous = cache / "spiderT.lua"
        previous.chmod(0)
        self.addCleanup(previous.chmod, 0o644)

        self.write_spider("new-cache")
        _, _, got = self.lmod_cache("unreadable")
        self.assertIn(f"eb-local: cannot read {previous}: AccessDenied; the cache was not changed\n", got.stderr)
        self.assert_previous_cache_refused(got, cache, stamp, old_stamp)
        previous.chmod(0o644)
        self.assertEqual(previous.read_text(), "old-cache\n")

    def test_lmod_cache_does_not_replace_a_previous_cache_too_large_to_keep(self):
        self.write_spider("old-cache")
        cache, stamp, ok = self.lmod_cache("oversized")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        old_stamp = stamp.stat().st_mtime_ns
        previous = cache / "spiderT.lua"
        # Sparse, so the file takes no space.
        os.truncate(previous, 64 * 1024 * 1024 + 1)

        self.write_spider("new-cache")
        _, _, got = self.lmod_cache("oversized")
        self.assertIn(f"eb-local: cannot read {previous}: larger than 64 MiB; the cache was not changed\n", got.stderr)
        self.assert_previous_cache_refused(got, cache, stamp, old_stamp)
        self.assertEqual(previous.stat().st_size, 64 * 1024 * 1024 + 1)
        with previous.open("rb") as f:
            self.assertEqual(f.read(10), b"old-cache\n")

    def in_place_stamp(self, name):
        # A timestamp in a directory the caller cannot write is rewritten
        # through the file itself.
        stamps = self.fresh_dir(f"stamps-{name}")
        stamp = stamps / "system.txt"
        stamp.write_text("old\n")
        inode = stamp.stat().st_ino
        # A second name for the inode, so the test can tell a restore
        # through that inode from a new file put in its place.
        os.link(stamp, stamps / "held")
        stamps.chmod(0o555)
        self.addCleanup(stamps.chmod, 0o755)
        self.write_spider("old-cache")
        cache, _, ok = self.lmod_cache(name, stamp=stamp)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertEqual((stamp.stat().st_ino, stamp.stat().st_size), (inode, 0))
        stamp.write_text("kept\n")
        os.utime(stamp, ns=(1_700_000_000_000_000_000, 1_700_000_000_000_000_000))
        self.write_spider("new-cache")
        return cache, stamp

    def test_lmod_cache_reports_a_failed_sync_or_close_of_a_timestamp_it_rewrites_in_place(self):
        for hook in HOOKS:
            with self.subTest(hook=hook):
                name = f"inplace-{hook.lower()}"
                cache, stamp = self.in_place_stamp(name)
                before = stamp.stat()
                _, _, got = self.lmod_cache(name, stamp=stamp, **{hook: "EIO", count(hook): "1"})
                self.assert_stamp_failed(got, stamp)
                self.assertNotIn("cannot restore", got.stderr)
                self.assertEqual((cache / "spiderT.lua").read_text(), "old-cache\n")
                after = stamp.stat()
                self.assertEqual(stamp.read_bytes(), b"kept\n")
                self.assertEqual((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns))
                held = stamp.parent / "held"
                self.assertEqual(held.read_bytes(), b"kept\n")
                self.assertEqual((held.stat().st_ino, held.stat().st_nlink), (before.st_ino, 2))

    def test_lmod_cache_reports_a_timestamp_it_cannot_restore_in_place(self):
        # With every sync or close failing, the restore of the timestamp
        # and of the previous cache fail too, and each is reported after
        # the failure that started it.
        for hook in HOOKS:
            with self.subTest(hook=hook):
                name = f"unrestored-{hook.lower()}"
                cache, stamp = self.in_place_stamp(name)
                _, _, got = self.lmod_cache(name, stamp=stamp, **{hook: "EIO"})
                self.assert_stamp_failed(got, stamp)
                first = f"eb-local: cannot write {stamp}: {EIO_TEXT}\n"
                restore = f"eb-local: cannot restore {stamp}: {EIO_TEXT}\n"
                self.assertIn(restore, got.stderr)
                self.assertLess(got.stderr.index(first), got.stderr.index(restore))
                cache_restore = f"eb-local: cannot restore {cache / 'spiderT.lua'}: {EIO_TEXT}\n"
                self.assertIn(cache_restore, got.stderr)
                self.assertLess(got.stderr.index(restore), got.stderr.index(cache_restore))
                self.assert_no_restore_temp(cache)

    def test_lmod_cache_verify_reports_each_failed_close(self):
        module = self.root / "module"
        module.write_text(MODULE)
        module.chmod(module.stat().st_mode | stat.S_IEXEC)
        verify = {
            "PATH": f"{self.root}:/usr/bin:/bin",
            "EB_LOCAL_MODULE_LOG": str(self.root / "module.log"),
            "EB_LOCAL_CACHED_INVENTORY": "GSL/2.8\n",
            "EB_LOCAL_UNCACHED_INVENTORY": "GSL/2.8\n",
        }
        self.write_spider("old-cache")
        cache, stamp, ok = self.lmod_cache("verify-cache", verify=True, **verify)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.write_spider("new-cache")

        verify_dir = re.escape(str(cache / ".eb-local-verify-"))
        for after, written in enumerate(("spiderT.lua", "timestamp", "lmodrc.lua")):
            with self.subTest(file=written):
                _, _, got = self.lmod_cache(
                    "verify-cache", verify=True, EB_LOCAL_TEST_CLOSE_ERRNO="EIO",
                    EB_LOCAL_TEST_CLOSE_AFTER=str(after), EB_LOCAL_TEST_CLOSE_COUNT="1", **verify,
                )
                self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
                self.assertRegex(got.stderr, rf"eb-local: cannot write {verify_dir}\w+/{written}: {re.escape(EIO_TEXT)}\n")
                self.assertNotIn("wrote ", got.stdout)
                self.assertEqual((cache / "spiderT.lua").read_text(), "old-cache\n")
                self.assertEqual([p.name for p in cache.iterdir() if p.name.startswith(".eb-local-verify-")], [])

        with self.subTest(file=stamp.name):
            _, _, got = self.lmod_cache(
                "verify-cache", verify=True, EB_LOCAL_TEST_CLOSE_ERRNO="EIO",
                EB_LOCAL_TEST_CLOSE_AFTER="3", EB_LOCAL_TEST_CLOSE_COUNT="1", **verify,
            )
            self.assert_stamp_failed(got, stamp)
            self.assertEqual((cache / "spiderT.lua").read_text(), "old-cache\n")


if __name__ == "__main__":
    unittest.main()
