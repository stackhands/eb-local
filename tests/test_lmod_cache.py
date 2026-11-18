#!/usr/bin/env python3
"""`eb-local lmod-cache` writes a spider cache Lmod will trust."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary

SPIDER = """#!/bin/sh
printf 'spider-cache\\n'
"""

MALFORMED_SPIDER = """#!/bin/sh
printf 'malformed candidate\\n'
"""

FAILING = """#!/bin/sh
echo spider-failed >&2
exit 9
"""

UPDATE = """#!/bin/sh
echo "$0 $@" >>"$EB_LOCAL_UPDATE_LOG"
exit 0
"""

MODULE = r"""#!/bin/sh
printf '%s|%s|%s\n' "${LMOD_IGNORE_CACHE-unset}" "$LMOD_RC" "$MODULEPATH" >>"$EB_LOCAL_MODULE_LOG"
candidate="$(dirname "$LMOD_RC")/spiderT.lua"
if [ "${LMOD_IGNORE_CACHE-}" = yes ]; then
    printf '%s\n' "$EB_LOCAL_UNCACHED_INVENTORY" >&2
else
    test -s "$candidate" || exit 7
    grep -q 'malformed candidate' "$candidate" && exit 8
    printf '%s\n' "$EB_LOCAL_CACHED_INVENTORY" >&2
fi
"""


def run(args, env=None):
    return subprocess.run(
        [binary.BIN, "lmod-cache", *args],
        capture_output=True,
        text=True,
        env=env,
    )


@unittest.skipUnless(binary.BIN, "EB_LOCAL_BIN names the Zig build")
class LmodCache(unittest.TestCase):
    def single_target(self, root, spider_body=SPIDER):
        spider = root / "spider"
        spider.write_text(spider_body)
        spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
        modules = root / "modules"
        modules.mkdir()
        cache = root / "cache"
        stamp = root / "system.txt"
        args = [
            "--modulepath", str(modules),
            "--cache-dir", str(cache),
            "--timestamp", str(stamp),
            "--spider", str(spider),
        ]
        return args, cache, stamp

    def verify_env(self, root, cached, uncached):
        module = root / "module"
        module.write_text(MODULE)
        module.chmod(module.stat().st_mode | stat.S_IEXEC)
        return {
            **os.environ,
            "PATH": f"{root}:{os.environ['PATH']}",
            "EB_LOCAL_MODULE_LOG": str(root / "module.log"),
            "EB_LOCAL_CACHED_INVENTORY": cached,
            "EB_LOCAL_UNCACHED_INVENTORY": uncached,
        }

    def test_a_successful_spider_leaves_the_timestamp_older_than_the_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spider = root / "spider"
            spider.write_text(SPIDER)
            spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
            modules = root / "modules"
            modules.mkdir()
            cache = root / "cache"
            stamp = root / "system.txt"
            got = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(cache),
                    "--timestamp",
                    str(stamp),
                    "--spider",
                    str(spider),
                ]
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            body = (cache / "spiderT.lua").read_text()
            self.assertEqual(body, "spider-cache\n")
            self.assertLess(stamp.stat().st_mtime, (cache / "spiderT.lua").stat().st_mtime)
            self.assertIn("spiderT.lua", got.stdout)
            self.assertIn("older than it", got.stdout)
            self.assertFalse((cache / "spiderT.lua.new").exists())

    def test_without_verify_stdout_stderr_and_status_are_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache, stamp = self.single_target(root)
            got = run(args)
            expected = f"wrote {cache}/spiderT.lua; {stamp} is older than it\n"
            self.assertEqual(
                (got.returncode, got.stdout.encode(), got.stderr.encode()),
                (0, expected.encode(), b""),
            )

    def test_verify_installs_a_candidate_with_the_same_normalized_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache, stamp = self.single_target(root)
            env = self.verify_env(
                root,
                "/modules:\nGSL/2.8 (D)\npigz/2.8\n",
                "pigz/2.8\nGSL/2.8\n",
            )
            got = run([*args, "--verify"], env=env)
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual((cache / "spiderT.lua").read_text(), "spider-cache\n")
            calls = (root / "module.log").read_text().splitlines()
            self.assertEqual(len(calls), 2)
            self.assertTrue(calls[0].startswith("unset|"))
            self.assertTrue(calls[1].startswith("yes|"))
            cached_call = calls[0].split("|")
            uncached_call = calls[1].split("|")
            self.assertEqual(cached_call[1], uncached_call[1])
            self.assertEqual(cached_call[2], uncached_call[2])
            self.assertEqual(cached_call[2], str(root / "modules"))
            self.assertFalse(any(path.name.startswith(".eb-local-verify-") for path in cache.iterdir()))
            self.assertLess(stamp.stat().st_mtime, (cache / "spiderT.lua").stat().st_mtime)

    def test_verify_accepts_lmod_terse_category_headers_and_loaded_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache, stamp = self.single_target(root)
            env = self.verify_env(
                root,
                "/modules:\nGSL/\nGSL/2.7\nGSL/2.8 (L,D)\nGSL/default -> GSL/2.8 (H)\npigz/\npigz/2.8 (L)\n",
                "/modules:\nGSL/\nGSL/2.7\nGSL/2.8 (D)\nGSL/default -> GSL/2.8 (H)\npigz/\npigz/2.8\n",
            )
            got = run([*args, "--verify"], env=env)
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual((cache / "spiderT.lua").read_text(), "spider-cache\n")
            self.assertLess(stamp.stat().st_mtime, (cache / "spiderT.lua").stat().st_mtime)

            bad_env = self.verify_env(root, "Lmod has detected the following error:\n", "GSL/2.8\n")
            bad = run([*args, "--verify"], env=bad_env)
            self.assertEqual(bad.returncode, 1, bad.stderr)
            self.assertIn("cannot parse the candidate cache inventory", bad.stderr)

    def test_verify_refuses_a_candidate_that_hides_a_module(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache, stamp = self.single_target(root)
            cache.mkdir()
            previous = cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp.write_text("old\n")
            before_stamp = stamp.stat().st_mtime_ns
            env = self.verify_env(root, "GSL/2.7\n", "GSL/2.7\nGSL/2.8\n")
            got = run([*args, "--verify"], env=env)
            self.assertEqual(got.returncode, 1, got.stderr)
            self.assertIn("inventories differ; the cache was not changed", got.stderr)
            self.assertEqual(previous.read_text(), "previous\n")
            self.assertEqual(stamp.stat().st_mtime_ns, before_stamp)
            self.assertEqual(sorted(path.name for path in cache.iterdir()), ["spiderT.lua"])

    def test_verify_refuses_a_candidate_lmod_cannot_parse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache, stamp = self.single_target(root, MALFORMED_SPIDER)
            cache.mkdir()
            previous = cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp.write_text("old\n")
            env = self.verify_env(root, "ignored\n", "ignored\n")
            got = run([*args, "--verify"], env=env)
            self.assertEqual(got.returncode, 1, got.stderr)
            self.assertIn("cannot parse the candidate cache inventory", got.stderr)
            self.assertEqual(previous.read_text(), "previous\n")
            self.assertEqual(stamp.read_text(), "old\n")
            self.assertEqual(sorted(path.name for path in cache.iterdir()), ["spiderT.lua"])

    def test_verify_cleans_missing_cache_dir_and_reports_missing_module_command(self):
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache, stamp = self.single_target(root)
            self.assertFalse(cache.exists())
            only_bash = root / "only-bash"
            only_bash.mkdir()
            (only_bash / "bash").symlink_to(shutil.which("bash"))
            env = {
                **os.environ,
                "PATH": str(only_bash),
                "LMOD_CMD": "",
            }
            got = run([*args, "--verify"], env=env)
            self.assertEqual(got.returncode, 127, got.stderr)
            self.assertIn("module command not found", got.stderr)
            self.assertFalse(cache.exists())
            self.assertFalse(stamp.exists())

    def test_a_failed_spider_leaves_the_previous_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spider = root / "spider"
            spider.write_text(FAILING)
            spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
            cache = root / "cache"
            cache.mkdir()
            previous = cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp = root / "system.txt"
            stamp.write_text("old\n")
            before_cache = previous.stat().st_mtime_ns
            before_stamp = stamp.stat().st_mtime_ns
            got = run(
                [
                    "--modulepath",
                    str(root / "modules"),
                    "--cache-dir",
                    str(cache),
                    "--timestamp",
                    str(stamp),
                    "--spider",
                    str(spider),
                ]
            )
            self.assertEqual(got.returncode, 9, got.stderr)
            self.assertEqual(previous.read_text(), "previous\n")
            self.assertEqual(previous.stat().st_mtime_ns, before_cache)
            self.assertEqual(stamp.stat().st_mtime_ns, before_stamp)
            self.assertIn("the cache was not changed", got.stderr)
            self.assertIn("spider-failed", got.stderr)

    def test_a_relative_cache_directory_is_refused(self):
        got = run(["--modulepath", "/modules", "--cache-dir", "cache", "--timestamp", "/tmp/stamp"])
        self.assertEqual(got.returncode, 2, got.stderr)
        self.assertIn("not an absolute path", got.stderr)

    def test_verify_ignores_caller_shell_startup_variables(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache_dir, stamp = self.single_target(root)
            env = self.verify_env(root, "GSL/2.8\n", "GSL/2.8\n")
            startup = root / "bash_env.sh"
            startup.write_text("echo 'injected noise on stdout'\n", encoding="utf-8")
            env["BASH_ENV"] = str(startup)
            env["SHELLOPTS"] = "xtrace"
            got = run([*args, "--verify"], env=env)
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            self.assertTrue((cache_dir / "spiderT.lua").exists())
            self.assertTrue(stamp.exists())

    def test_prefix_cannot_be_combined_with_single_target_options(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "calls.log"
            updater = root / "update_lmod_system_cache_files"
            updater.write_text(UPDATE)
            updater.chmod(updater.stat().st_mode | stat.S_IEXEC)
            cpu = root / "versions/2026.06/software/linux/x86_64/amd/zen4"
            (cpu / "modules/all").mkdir(parents=True)
            cache = cpu / ".lmod/cache"
            cache.mkdir(parents=True)
            previous = cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp = cache / "timestamp"
            stamp.write_text("old\n")
            env = {**os.environ, "EB_LOCAL_UPDATE_LOG": str(log)}
            for flag, val in (
                ("--modulepath", str(cpu / "modules/all")),
                ("--cache-dir", str(cache)),
                ("--timestamp", str(stamp)),
            ):
                with self.subTest(flag=flag):
                    got = run(
                        [
                            "--prefix",
                            str(root),
                            flag,
                            val,
                            "--update-cmd",
                            str(updater),
                        ],
                        env=env,
                    )
                    self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                    self.assertEqual(got.stdout, "")
                    self.assertEqual(
                        got.stderr,
                        "eb-local: lmod-cache takes either --prefix or --modulepath, --cache-dir and --timestamp\n",
                    )
                    self.assertFalse(log.exists())
                    self.assertEqual(previous.read_text(), "previous\n")
                    self.assertEqual(stamp.read_text(), "old\n")

    def test_mode_specific_options_are_rejected_when_used_in_the_other_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "calls.log"
            updater = root / "update_lmod_system_cache_files"
            updater.write_text(UPDATE)
            updater.chmod(updater.stat().st_mode | stat.S_IEXEC)
            spider = root / "spider"
            spider.write_text(SPIDER)
            spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
            cpu = root / "versions/2026.06/software/linux/x86_64/amd/zen4"
            (cpu / "modules/all").mkdir(parents=True)
            cache = root / "cache"
            stamp = root / "timestamp"
            env = {**os.environ, "EB_LOCAL_UPDATE_LOG": str(log)}

            bad_prefix = run(
                ["--prefix", str(root), "--spider", str(spider), "--update-cmd", str(updater)],
                env=env,
            )
            self.assertEqual(bad_prefix.returncode, 2, bad_prefix.stdout + bad_prefix.stderr)
            self.assertEqual(bad_prefix.stdout, "")
            self.assertIn("--spider applies only with --modulepath", bad_prefix.stderr)
            self.assertFalse(log.exists())

            for flag, val in (
                ("--eessi-version", "2026.06"),
                ("--update-cmd", str(updater)),
            ):
                with self.subTest(flag=flag):
                    bad_single = run(
                        [
                            "--modulepath",
                            str(cpu / "modules/all"),
                            "--cache-dir",
                            str(cache),
                            "--timestamp",
                            str(stamp),
                            "--spider",
                            str(spider),
                            flag,
                            val,
                        ],
                        env=env,
                    )
                    self.assertEqual(bad_single.returncode, 2, bad_single.stdout + bad_single.stderr)
                    self.assertEqual(bad_single.stdout, "")
                    self.assertIn("apply only with --prefix", bad_single.stderr)
                    self.assertFalse(cache.exists())
                    self.assertFalse(stamp.exists())
                    self.assertFalse(log.exists())

    def test_prefix_dry_run_lists_cpu_and_accelerator_module_trees(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "versions/2026.06/software/linux/x86_64/amd/zen4"
            (base / "modules/all").mkdir(parents=True)
            (base / "accel/nvidia/cc90/modules/all").mkdir(parents=True)
            got = run(["--prefix", str(root), "--dry-run"])
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertIn(str(base), got.stdout)
            self.assertIn("modules/all", got.stdout)
            self.assertIn("accel/nvidia/cc90/modules/all", got.stdout)

    def test_prefix_invokes_lmods_cache_updater_for_each_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "calls.log"
            updater = root / "update_lmod_system_cache_files"
            updater.write_text(UPDATE)
            updater.chmod(updater.stat().st_mode | stat.S_IEXEC)
            cpu = root / "versions/2026.06/software/linux/x86_64/amd/zen4"
            (cpu / "modules/all").mkdir(parents=True)
            (cpu / "accel/nvidia/cc90/modules/all").mkdir(parents=True)
            env = {**os.environ, "EB_LOCAL_UPDATE_LOG": str(log)}
            got = subprocess.run(
                [binary.BIN, "lmod-cache", "--prefix", str(root), "--update-cmd", str(updater)],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            lines = log.read_text().strip().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertIn("modules/all", lines[0])
            self.assertIn("accel/nvidia/cc90/modules/all", lines[0])
            self.assertIn(f"-d {cpu}/.lmod/cache", lines[0])

    def test_timestamp_failure_restores_previous_cache_and_removes_created_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spider = root / "spider"
            spider.write_text(SPIDER)
            spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
            modules = root / "modules"
            modules.mkdir()

            new_cache = root / "missing" / "cache"
            bad_stamp = root / "no-such-dir" / "timestamp"
            got_new = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(new_cache),
                    "--timestamp",
                    str(bad_stamp),
                    "--spider",
                    str(spider),
                ]
            )
            self.assertEqual(got_new.returncode, 1, got_new.stdout + got_new.stderr)
            self.assertFalse(new_cache.parent.exists())

            existing_cache = root / "existing-cache"
            existing_cache.mkdir()
            previous = existing_cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp_dir = root / "stamp-is-dir"
            stamp_dir.mkdir()
            got_existing = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(existing_cache),
                    "--timestamp",
                    str(stamp_dir),
                    "--spider",
                    str(spider),
                ]
            )
            self.assertEqual(got_existing.returncode, 1, got_existing.stdout + got_existing.stderr)
            self.assertEqual(previous.read_text(), "previous\n")
            self.assertEqual(sorted(p.name for p in existing_cache.iterdir()), ["spiderT.lua"])

    def test_verify_writes_atomically_refuses_symlink_and_rolls_back_on_timestamp_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, _, _ = self.single_target(root)
            modules = root / "modules"
            env = self.verify_env(root, "GSL/2.8\n", "GSL/2.8\n")

            new_cache = root / "verify-missing" / "cache"
            bad_stamp = root / "no-such-dir" / "timestamp"
            got_new = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(new_cache),
                    "--timestamp",
                    str(bad_stamp),
                    "--spider",
                    str(root / "spider"),
                    "--verify",
                ],
                env=env,
            )
            self.assertEqual(got_new.returncode, 1, got_new.stdout + got_new.stderr)
            self.assertFalse(new_cache.parent.exists())

            existing_cache = root / "verify-existing"
            existing_cache.mkdir()
            previous = existing_cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp_dir = root / "verify-stamp-dir"
            stamp_dir.mkdir()
            got_existing = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(existing_cache),
                    "--timestamp",
                    str(stamp_dir),
                    "--spider",
                    str(root / "spider"),
                    "--verify",
                ],
                env=env,
            )
            self.assertEqual(got_existing.returncode, 1, got_existing.stdout + got_existing.stderr)
            self.assertEqual(previous.read_text(), "previous\n")

            sym_cache = root / "verify-symlink"
            sym_cache.mkdir()
            target = root / "outside-cache.lua"
            target.write_text("outside\n")
            link = sym_cache / "spiderT.lua"
            link.symlink_to(target)
            sym_stamp = root / "sym-stamp"
            got_sym = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(sym_cache),
                    "--timestamp",
                    str(sym_stamp),
                    "--spider",
                    str(root / "spider"),
                    "--verify",
                ],
                env=env,
            )
            self.assertEqual(got_sym.returncode, 1, got_sym.stdout + got_sym.stderr)
            self.assertIn("symlink", got_sym.stderr)
            self.assertTrue(link.is_symlink())
            self.assertEqual(target.read_text(), "outside\n")

    def test_eessi_version_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefix = root / "prefix"
            (prefix / "versions").mkdir(parents=True)
            escaped = root / "escape" / "software" / "linux" / "x86_64" / "amd" / "zen4"
            (escaped / "modules" / "all").mkdir(parents=True)
            log = root / "calls.log"
            updater = root / "update_lmod_system_cache_files"
            updater.write_text(UPDATE)
            updater.chmod(updater.stat().st_mode | stat.S_IEXEC)
            env = {**os.environ, "EB_LOCAL_UPDATE_LOG": str(log)}

            for bad in ("../../escape", "2026.06/extra", ".", ".."):
                with self.subTest(eessi_version=bad):
                    got = run(
                        [
                            "--prefix",
                            str(prefix),
                            "--eessi-version",
                            bad,
                            "--update-cmd",
                            str(updater),
                        ],
                        env=env,
                    )
                    self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                    self.assertEqual(got.stdout, "")
                    self.assertIn("--eessi-version", got.stderr)
                    self.assertFalse(log.exists())

    def test_timestamp_symlink_is_refused_without_clobbering_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args, cache_dir, stamp = self.single_target(root)
            outside = root / "outside-stamp"
            outside.write_text("keep-me\n", encoding="utf-8")
            stamp.symlink_to(outside)

            got = run(args)
            self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
            self.assertIn("symlink", got.stderr)
            self.assertTrue(stamp.is_symlink())
            self.assertEqual(outside.read_text(encoding="utf-8"), "keep-me\n")
            self.assertFalse((cache_dir / "spiderT.lua").exists())


if __name__ == "__main__":
    unittest.main()
