#!/usr/bin/env python3
"""eb-local eb drops bash startup variables so BASH_ENV and SHELLOPTS do not leak."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary

INIT = r'''
export EESSI_SOFTWARE_PATH="$EESSI_CVMFS_REPO/versions/2026.06/software/linux/x86_64/amd/zen4"
export EESSI_SITE_SOFTWARE_PATH="$EESSI_CVMFS_REPO/host_injections/2026.06/software/linux/x86_64/amd/zen4"
module() {
    if [ "$1" = load ]; then
        export EASYBUILD_PREFIX="${WORKING_DIR:-/tmp/$USER}/easybuild"
        export EASYBUILD_INSTALLPATH="${EESSI_USER_INSTALL:-$HOME/eessi}/versions/2026.06/software/linux/x86_64/amd/zen4"
    fi
}
'''

EB = r'''#!/bin/sh
printf 'BASH_ENV=%s\nENV=%s\nSHELLOPTS=%s\nBASHOPTS=%s\n' \
    "${BASH_ENV-unset}" "${ENV-unset}" "${SHELLOPTS-unset}" "${BASHOPTS-unset}"
'''


@unittest.skipUnless(binary.BIN, "eb is a feature of the Zig build")
class ExtendCleanShellEnv(unittest.TestCase):
    def test_eb_drops_bash_env_and_shellopts(self):
        with tempfile.TemporaryDirectory(prefix="eb-local-extend-clean-") as tmp:
            root = Path(tmp).resolve()
            init = root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
            init.parent.mkdir(parents=True)
            init.write_text(INIT, encoding="utf-8")

            bin_dir = root / "bin"
            bin_dir.mkdir()
            eb = bin_dir / "eb"
            eb.write_text(EB, encoding="utf-8")
            eb.chmod(0o755)

            home = root / "home"
            home.mkdir()
            marker = root / "bash-env-ran"
            evil = root / "evil-bash-env.sh"
            evil.write_text(f"touch '{marker}'\n", encoding="utf-8")

            env = dict(
                os.environ,
                PATH=f"{bin_dir}:/usr/bin:/bin",
                HOME=str(home),
                USER="alice",
                EESSI_CVMFS_REPO=str(root / "repo"),
                SHELLOPTS="xtrace",
                BASHOPTS="cmdhist",
                ENV=str(evil),
            )
            env["BASH_ENV"] = str(evil)

            run = subprocess.run(
                [binary.BIN, "eb", "x.eb"],
                env=env,
                cwd=root,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertFalse(marker.exists(), run.stderr)
            self.assertNotIn("+ unset EB_LOCAL_EESSI_EXTEND", run.stderr)
            self.assertEqual(
                run.stdout.splitlines(),
                [
                    "BASH_ENV=unset",
                    "ENV=unset",
                    "SHELLOPTS=unset",
                    "BASHOPTS=unset",
                ],
            )


if __name__ == "__main__":
    unittest.main()
