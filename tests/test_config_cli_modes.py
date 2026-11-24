#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local config` modes, `--get`, `--env`, and `--check`."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary
import hostile_fs


@unittest.skipUnless(binary.ZIG, "config is a feature of the Zig build")
class ConfigCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-config-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.site = self.root / "site.toml"
        self.site.write_text(
            '[storage]\nnode_local_root = "/local"\n'
            '[secrets]\nTOKEN = "env:ABSENT_TOK"\n'
            '[eessi]\nEESSI_FOO = "bar"\n'
            '[build.node_types]\nmilan = "--constraint=milan"\n',
            encoding="utf-8",
        )
        self.site.chmod(0o600)

    def run_config(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": str(self.site),
        }
        env.pop("ABSENT_TOK", None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.ZIG, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_mode_conflicts_unknown_flags_and_explain_exit_two(self):
        cases = (
            (["config", "--check", "--env"], "config takes --check, --env or --get"),
            (["config", "--check", "--get", "prefix"], "config takes --check, --env or --get"),
            (["config", "--env", "--get", "prefix"], "config takes --check, --env or --get"),
            (["config", "--env", "--json"], "config --json does not go with --env"),
            (["config", "--get", "prefix", "--json"], "config --json does not go with --get"),
            (["config", "--get", "prefix", "--get=stack.module"], "config takes one --get"),
            (["config", "--unknown"], "config does not know"),
            (["--explain", "config"], "--explain goes with a recipe or with eb"),
        )
        for args, msg in cases:
            with self.subTest(args=args):
                got = self.run_config(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(msg, got.stderr)

    def test_get_returns_values_sources_empty_exit_one_and_unknown_exit_two(self):
        for key in ("profile", "project", "dev.modules", "build.allocation_hint", "eessi.NOPE", "secrets.NOPE"):
            with self.subTest(empty=key):
                got = self.run_config(["config", "--get", key])
                self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")

        tok = self.run_config(["config", "--get", "secrets.TOKEN"], ABSENT_TOK="super-secret-value")
        self.assertEqual(tok.returncode, 0, tok.stderr)
        self.assertEqual(tok.stdout, "env:ABSENT_TOK\n")
        self.assertNotIn("super-secret-value", tok.stdout)

        eessi = self.run_config(["config", "--get=eessi.EESSI_FOO"])
        self.assertEqual(eessi.returncode, 0, eessi.stderr)
        self.assertEqual(eessi.stdout, "bar\n")

        nt = self.run_config(["config", "--get", "build.node_types.milan"])
        self.assertEqual(nt.returncode, 0, nt.stderr)
        self.assertEqual(nt.stdout, "--constraint=milan\n")

        bad = self.run_config(["config", "--get", "no.such.key"])
        self.assertEqual(bad.returncode, 2, bad.stdout + bad.stderr)
        self.assertIn("unknown configuration key", bad.stderr)

    def test_check_json_fails_on_unresolvable_secret_and_env_exports_clear_profile(self):
        chk = self.run_config(["config", "--check", "--json"])
        self.assertEqual(chk.returncode, 1, chk.stdout + chk.stderr)
        doc = json.loads(chk.stdout)
        self.assertTrue(doc["check_failed"])
        self.assertEqual(doc["secrets"][0]["status"], "failed")

        env_out = self.run_config(["config", "--env"])
        self.assertEqual(env_out.returncode, 0, env_out.stderr)
        self.assertIn("export EB_LOCAL_PROFILE=''\n", env_out.stdout)
        self.assertIn("export EB_LOCAL_SECRET_TOKEN=env:ABSENT_TOK\n", env_out.stdout)
        self.assertIn("export EESSI_FOO=bar\n", env_out.stdout)

    def test_eessi_table_rejects_reserved_install_and_toolchain_variables(self):
        for var in ("EESSI_USER_INSTALL", "EESSI_SITE_TOP_LEVEL_TOOLCHAINS_ZEN4"):
            with self.subTest(var=var):
                bad = self.root / f"bad-{var}.toml"
                bad.write_text(f'[eessi]\n{var} = "val"\n', encoding="utf-8")
                bad.chmod(0o600)
                got = self.run_config(["config"], EB_LOCAL_CONFIG=str(bad))
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(f"eessi.{var}: [eessi] sets EESSI_* variables other than", got.stderr)

    def test_config_refuses_hostile_input_files(self):
        def make_inputs(base: Path):
            entries = []
            d = base / "dir.toml"
            d.mkdir()
            entries.append(("dir", d, str(d).encode()))

            pipe = base / "pipe.toml"
            os.mkfifo(pipe, 0o600)
            entries.append(("fifo", pipe, str(pipe).encode()))

            link, _ = hostile_fs.dangling_symlink(base / "dangling.toml", base / "absent.toml")
            entries.append(("dangling", link, b"symbolic link"))

            nonutf = base / "nonutf.toml"
            nonutf.write_bytes(b'prefix = "\xff\xfe"\n')
            nonutf.chmod(0o600)
            entries.append(("nonutf", nonutf, b"the file is not UTF-8"))

            bom = base / "bom.toml"
            bom.write_bytes(b'\xef\xbb\xbfprefix = "/tmp/x"\n')
            bom.chmod(0o600)
            entries.append(("bom", bom, b""))

            big = hostile_fs.oversized_file(base / "big.toml", 2 * 1024 * 1024)
            entries.append(("oversized", big, b"StreamTooLong"))
            return entries

        explicit_dir = self.root / "explicit"
        explicit_dir.mkdir()
        for kind, path, needle in make_inputs(explicit_dir):
            with self.subTest(mode="explicit", kind=kind):
                env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "EB_LOCAL_CONFIG": ""}
                got = subprocess.run(
                    [binary.ZIG, "--config", str(path), "config", "--check"],
                    env=env,
                    cwd=self.root,
                    capture_output=True,
                    text=False,
                    timeout=2,
                    check=False,
                )
                self.assertEqual(got.returncode, 2, got.stderr)
                self.assertEqual(got.stdout, b"")
                self.assertTrue(len(got.stderr.strip()) > 0)
                self.assertIn(str(path).encode(), got.stderr)
                if needle:
                    self.assertIn(needle, got.stderr)

        user_cases = (
            ("dir", b""),
            ("fifo", b""),
            ("dangling", b"symbolic link"),
            ("nonutf", b"the file is not UTF-8"),
            ("bom", b""),
            ("oversized", b"StreamTooLong"),
        )
        for kind, needle in user_cases:
            with self.subTest(mode="user", kind=kind):
                user_home = self.root / f"home-{kind}"
                cfg_dir = user_home / ".config" / "eb-local"
                cfg_dir.mkdir(parents=True)
                target = cfg_dir / "config.toml"
                if kind == "dir":
                    target.mkdir()
                elif kind == "fifo":
                    os.mkfifo(target, 0o600)
                elif kind == "dangling":
                    hostile_fs.dangling_symlink(target, user_home / "absent.toml")
                elif kind == "nonutf":
                    target.write_bytes(b'prefix = "\xff\xfe"\n')
                    target.chmod(0o600)
                elif kind == "bom":
                    target.write_bytes(b'\xef\xbb\xbfprefix = "/tmp/x"\n')
                    target.chmod(0o600)
                elif kind == "oversized":
                    hostile_fs.oversized_file(target, 2 * 1024 * 1024)

                env = {"PATH": "/usr/bin:/bin", "HOME": str(user_home), "EB_LOCAL_CONFIG": ""}
                got = subprocess.run(
                    [binary.ZIG, "config", "--check"],
                    env=env,
                    cwd=self.root,
                    capture_output=True,
                    text=False,
                    timeout=2,
                    check=False,
                )
                self.assertEqual(got.returncode, 2, got.stderr)
                self.assertEqual(got.stdout, b"")
                self.assertTrue(len(got.stderr.strip()) > 0)
                self.assertIn(str(target).encode(), got.stderr)
                if needle:
                    self.assertIn(needle, got.stderr)


if __name__ == "__main__":
    unittest.main()
