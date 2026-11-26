#!/usr/bin/env python3
"""Configured install and EESSI settings supplied to `eb-local eb`."""
import json
from pathlib import Path

from test_storage import StorageFixture


class ConfiguredEb(StorageFixture):
    def setUp(self):
        super().setUp()
        self.config = self.root / "site.toml"
        self.env["EB_LOCAL_CONFIG"] = str(self.config)
        self.config.write_text(
            f'prefix = "{self.prefix}"\n'
            "[storage]\n"
            f'node_local_root = "{self.nodes}"\n'
            'node_local_fstype = "xfs"\n'
            "[build]\n"
            'site_toolchains = ["intel/2026.1"]\n'
            "[eessi]\n"
            'EESSI_CUSTOM_SITE_OPT = "configured"\n',
            encoding="utf-8",
        )
        self.config.chmod(0o600)
        init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init.parent.mkdir(parents=True)
        init.write_text(
            '. "$CONTROL_ROOT/doubles.sh"\n'
            "export EESSI_VERSION=2026.06\n",
            encoding="utf-8",
        )
        self.env.update(EESSI_CVMFS_REPO=str(self.root / "repo"), USER="alice")

    def captured(self, args=None, **overrides):
        run = self.run_wrapper(args or ["eb", "recipe.eb"], **overrides)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return json.loads((self.root / "eb.json").read_text(encoding="utf-8"))

    def test_configured_user_prefix_settings_and_durable_sources_reach_eb(self):
        got = self.captured()
        self.assertEqual(got["user"], str(self.prefix))
        self.assertIsNone(got["project"])
        self.assertEqual(got["eessi_custom"], "configured")
        self.assertEqual(
            got["site_toolchains"],
            '[{"name": "intel", "version": "2026.1"}]',
        )
        self.assertEqual(
            got["paths"]["EASYBUILD_SOURCEPATH"],
            str(self.prefix / ".eb-local" / "sources"),
        )

    def test_exported_install_and_eessi_settings_override_configuration(self):
        chosen = self.root / "chosen"
        sources = self.root / "chosen-sources"
        got = self.captured(
            EESSI_USER_INSTALL=str(chosen),
            EESSI_CUSTOM_SITE_OPT="shell",
            EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06="shell-toolchains",
            EASYBUILD_SOURCEPATH=str(sources),
        )
        self.assertEqual(got["user"], str(chosen))
        self.assertEqual(got["eessi_custom"], "shell")
        self.assertEqual(got["site_toolchains"], "shell-toolchains")
        self.assertEqual(got["paths"]["EASYBUILD_SOURCEPATH"], str(sources))

    def test_configured_project_matches_env_selection(self):
        project = self.root / "project"
        project.mkdir()
        project.chmod(0o2770)
        self.config.write_text(
            self.config.read_text(encoding="utf-8").replace(
                f'prefix = "{self.prefix}"',
                f'project = "{project}"',
            ),
            encoding="utf-8",
        )
        got = self.captured()
        self.assertIsNone(got["user"])
        self.assertEqual(got["project"], str(project))
        self.assertEqual(
            got["paths"]["EASYBUILD_SOURCEPATH"],
            str(project / ".eb-local" / "sources"),
        )

    def test_project_profile_and_config_select_eb_as_they_select_env(self):
        project = self.root / "explicit-project"
        project.mkdir()
        project.chmod(0o2770)
        got = self.captured(["--project", str(project), "eb", "recipe.eb"])
        self.assertEqual(got["project"], str(project))

        self.env.pop("EB_LOCAL_PREFIX")
        profile_prefix = self.root / "profile-prefix"
        with self.config.open("a", encoding="utf-8") as handle:
            handle.write(f'\n[profile.alt]\nprefix = "{profile_prefix}"\n')
        got = self.captured(["eb", "--profile", "alt", "recipe.eb"])
        self.assertEqual(got["user"], str(profile_prefix))

        other = self.root / "other.toml"
        config_prefix = self.root / "config-prefix"
        other.write_text(f'prefix = "{config_prefix}"\n', encoding="utf-8")
        other.chmod(0o600)
        got = self.captured(
            ["eb", "--config", str(other), "recipe.eb"],
            EB_LOCAL_CONFIG="",
        )
        self.assertEqual(got["user"], str(config_prefix))


if __name__ == "__main__":
    import unittest

    unittest.main()
