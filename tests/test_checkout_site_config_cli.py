#!/usr/bin/env python3
"""Checkout-root site configuration discovery from `<checkout>/zig-out/bin/eb-local`."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "checkout site-file discovery belongs to the Zig binary")
class CheckoutSiteConfigCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-checkout-cfg-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.exe = self.root / "zig-out" / "bin" / "eb-local"
        self.exe.parent.mkdir(parents=True)
        shutil.copy2(binary.BIN, self.exe)
        self.exe.chmod(0o755)
        self.xdg = self.root / "xdg"
        self.home = self.root / "home"
        self.home.mkdir()

    def run_bin(self, args, **extra):
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("EB_LOCAL_")
        }
        env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.xdg),
            SLURM_JOB_ID="",
        )
        env.update(extra)
        return subprocess.run(
            [self.exe, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def settings_map(self, args=None):
        run = self.run_bin(args or ["config", "--json"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads(run.stdout)
        return {row["key"]: row for row in doc["settings"]}

    def test_checkout_legacy_eb_local_conf_is_loaded_without_shim_or_env(self):
        legacy = self.root / "eb-local.conf"
        legacy.write_text("node_local_root = /local/from-checkout-conf\n", encoding="utf-8")
        legacy.chmod(0o600)

        node_root = self.settings_map()["storage.node_local_root"]
        self.assertEqual(node_root["value"], "/local/from-checkout-conf")
        self.assertEqual(node_root["from"], f"site {legacy}:1")

    def test_checkout_config_toml_beats_checkout_eb_local_conf_and_binary_dir_beats_checkout(self):
        legacy = self.root / "eb-local.conf"
        legacy.write_text("node_local_root = /local/legacy\n", encoding="utf-8")
        legacy.chmod(0o600)

        checkout_toml = self.root / "config.toml"
        checkout_toml.write_text('[storage]\nnode_local_root = "/local/checkout-toml"\n', encoding="utf-8")
        checkout_toml.chmod(0o600)

        node_root = self.settings_map()["storage.node_local_root"]
        self.assertEqual(node_root["value"], "/local/checkout-toml")
        self.assertEqual(node_root["from"], f"site {checkout_toml}:2")

        beside_bin = self.exe.parent / "config.toml"
        beside_bin.write_text('[storage]\nnode_local_root = "/local/beside-bin"\n', encoding="utf-8")
        beside_bin.chmod(0o600)

        node_root2 = self.settings_map()["storage.node_local_root"]
        self.assertEqual(node_root2["value"], "/local/beside-bin")
        self.assertEqual(node_root2["from"], f"site {beside_bin}:2")

    def test_checkout_site_file_combines_with_xdg_user_config_without_exporting_eb_local_config(self):
        legacy = self.root / "eb-local.conf"
        legacy.write_text("node_local_root = /local/site\n", encoding="utf-8")
        legacy.chmod(0o600)

        user_cfg = self.xdg / "eb-local" / "config.toml"
        user_cfg.parent.mkdir(parents=True)
        user_cfg.write_text('prefix = "/tmp/user-eessi"\n', encoding="utf-8")
        user_cfg.chmod(0o600)

        guard_bin = self.root / "guard-bin"
        guard_bin.mkdir()
        seen = self.root / "guard-env.txt"
        guard = guard_bin / "eessi-arch-guard"
        guard.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"${{EB_LOCAL_CONFIG-unset}}\" > '{seen}'\n"
            "printf 'export EESSI_SOFTWARE_SUBDIR=x86_64/generic\\n'\n",
            encoding="utf-8",
        )
        guard.chmod(0o755)

        settings = self.settings_map()
        self.assertEqual(settings["storage.node_local_root"]["value"], "/local/site")
        self.assertEqual(settings["prefix"]["value"], "/tmp/user-eessi")

        self.run_bin(
            ["doctor"],
            PATH=f"{guard_bin}:/usr/bin:/bin",
            SLURM_JOB_ID="1",
            EESSI_SOFTWARE_SUBDIR="x86_64/generic",
        )
        self.assertEqual(seen.read_text(encoding="utf-8"), "unset\n")

    def test_checkout_site_symlink_or_group_writable_file_is_refused(self):
        real = self.root / "real.conf"
        real.write_text("node_local_root = /local/real\n", encoding="utf-8")
        real.chmod(0o600)
        link = self.root / "eb-local.conf"
        link.symlink_to(real)

        sym = self.run_bin(["config"])
        self.assertEqual(sym.returncode, 2, sym.stdout + sym.stderr)
        self.assertIn("symbolic link", sym.stderr)

        link.unlink()
        real.rename(link)
        link.chmod(0o664)
        writable = self.run_bin(["config"])
        self.assertEqual(writable.returncode, 2, writable.stdout + writable.stderr)
        self.assertIn("writable by group or others", writable.stderr)


if __name__ == "__main__":
    unittest.main()
