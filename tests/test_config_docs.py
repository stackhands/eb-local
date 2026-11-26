#!/usr/bin/env python3
"""The configuration reference, docs/orgmode/reference/configuration.org,
against what `eb-local config` prints: every setting it shows has a row in
the page's table of settings, and each default there is what it prints for
a setting nothing sets.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import binary

PAGE = Path(__file__).resolve().parents[1] / "docs" / "orgmode" / "reference" / "configuration.org"


def settings_table(page):
    """Key -> default cell of the table under * Settings."""
    section = page.split("\n* Settings\n", 1)[1].split("\n* ", 1)[0]
    rows = {}
    for line in section.splitlines():
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if line.startswith("| =") and len(cells) == 4:
            rows[cells[0].strip("=")] = cells[2]
    return rows


@unittest.skipUnless(binary.ZIG, "eb-local config is a command of the Zig build")
class ConfigurationReference(unittest.TestCase):
    def test_each_setting_config_shows_has_its_row_and_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            # An empty site file named with --config, which the caller owns
            # as it owns the program, keeps /etc out of it.
            site = Path(tmp) / "site.toml"
            site.write_text("")
            site.chmod(0o644)
            home = Path(tmp) / "home"
            home.mkdir()
            run = subprocess.run([binary.ZIG, "--config", str(site), "config"], capture_output=True, text=True,
                                 env={"HOME": str(home), "PATH": os.environ["PATH"]})
        self.assertEqual(run.returncode, 0, run.stderr)
        rows = settings_table(PAGE.read_text())
        shown = {"eessi": "[eessi]", "secrets": "[secrets]"}
        checked = []
        for line in run.stdout.splitlines():
            key, rest = line.split(None, 1)
            if key == "profile":
                continue
            key = shown.get(key, key)
            self.assertIn(key, rows, f"{PAGE}: no row for {key}")
            value = rest.removesuffix("   [default]").replace(str(home), "$HOME")
            self.assertEqual(rows[key], f"={value}=", f"{PAGE}: the default of {key}")
            checked.append(key)
        self.assertIn("storage.node_local_mount", checked)
        self.assertEqual(sorted(set(rows) - set(checked)), ["default_profile", "project"])


class SecretNamesDocumented(unittest.TestCase):
    def test_refused_secret_names_documented(self):
        config_zig = (Path(__file__).resolve().parents[1] / "src" / "config.zig").read_text()
        m_names = re.search(r'const refused = \[_\]\[\]const u8\{([^}]+)\};', config_zig)
        m_prefixes = re.search(r'const refused_prefixes = \[_\]\[\]const u8\{([^}]+)\};', config_zig)
        self.assertIsNotNone(m_names)
        self.assertIsNotNone(m_prefixes)
        refused_names = re.findall(r'"([^"]+)"', m_names.group(1))
        refused_prefixes = re.findall(r'"([^"]+)"', m_prefixes.group(1))
        secrets_section = PAGE.read_text().split("\n** [secrets]\n", 1)[1].split("\n| Source", 1)[0]
        documented = set(re.findall(r"=([A-Za-z0-9_]+)=", secrets_section))
        for name in refused_names + refused_prefixes:
            self.assertIn(name, documented, f"{PAGE} [secrets] does not list refused secret name {name}")


if __name__ == "__main__":
    unittest.main()
