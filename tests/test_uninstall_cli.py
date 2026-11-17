#!/usr/bin/env python3
"""eb-local uninstall and restore, through the command line of the Zig build.

An installation made by EasyBuild through EESSI-extend is read-only, so
rm -rf cannot remove it; uninstall makes it writable and removes it, for
every CPU target, with rtrash or, asked, for good. restore brings back what
went to the trash, read-only again.
"""
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import unittest

import binary
from test_storage import StorageFixture

# Behaves as rtrash put does: rm(1) flags, and a directory without -r is
# refused with status 1 after the other operands are trashed.
RTRASH = r'''#!/bin/sh
[ "$1" = put ] || exit 64
shift
rec=
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        -r|-R|--recursive) rec=1; shift ;;
        -*) shift ;;
        *) break ;;
    esac
done
rc=0
for f in "$@"; do
    if [ -d "$f" ] && [ -z "$rec" ]; then echo "rtrash: cannot remove '$f': Is a directory" >&2; rc=1; continue; fi
    printf '%s\n' "$f" >> "$CONTROL_ROOT/trashed"; chmod -R u+w -- "$f"; rm -rf -- "$f"
done
exit $rc
'''

# A FreeDesktop trash, kept as rtrash 0.1.4 keeps it: put renames each
# operand into $XDG_DATA_HOME/Trash/files beside a .trashinfo naming where it
# was; list --json prints the entries; restore takes one original path, and
# --trash-dir=DIR but not --, and renames the entry back, over nothing.
TRASH = "#!" + sys.executable + "\n" + r'''
import datetime, json, os, sys
from pathlib import Path

trash = Path(os.environ["XDG_DATA_HOME"]) / "Trash"
files, info = trash / "files", trash / "info"
files.mkdir(parents=True, exist_ok=True)
info.mkdir(exist_ok=True)


def entries():
    for record in sorted(info.glob("*.trashinfo")):
        fields = dict(line.split("=", 1) for line in record.read_text().splitlines()[1:])
        yield {"deletion_date": fields["DeletionDate"], "original": fields["Path"],
               "name": record.name[:-len(".trashinfo")], "trash_dir": str(trash)}


command, args = sys.argv[1], sys.argv[2:]
rc = 0
if command == "put":
    for path in args[args.index("--") + 1:]:
        if os.path.isdir(path) and "-r" not in args:
            print(f"rtrash: cannot remove '{path}': Is a directory", file=sys.stderr)
            rc = 1
            continue
        name = base = os.path.basename(path)
        while os.path.lexists(files / name):
            name += "_"
        record = info / f"{name}.trashinfo"
        record.write_text(f"[Trash Info]\nPath={path}\nDeletionDate={datetime.datetime.now():%Y-%m-%dT%H:%M:%S}\n")
        try:
            os.rename(path, files / name)
        except OSError as e:
            record.unlink()
            print(f"rtrash: cannot move '{path}': {e.strerror}", file=sys.stderr)
            rc = 1
elif command == "list" and args == ["--json"]:
    print(json.dumps(list(entries()), indent=2))
elif command == "restore":
    if any(a.startswith("-") and not a.startswith("--trash-dir=") for a in args):
        sys.exit(2)
    pinned = [a.split("=", 1)[1] for a in args if a.startswith("--trash-dir=")]
    (target,) = [a for a in args if not a.startswith("-")]
    found = [e for e in entries() if e["original"] == target and (not pinned or e["trash_dir"] in pinned)]
    if len(found) != 1 or os.path.lexists(target):
        print(f"rtrash: cannot restore '{target}'", file=sys.stderr)
        sys.exit(1)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    os.rename(files / found[0]["name"], target)
    (info / f"{found[0]['name']}.trashinfo").unlink()
    print(f"restored '{target}'")
else:
    rc = 64
sys.exit(rc)
'''


@unittest.skipUnless(binary.BIN, "uninstall is a feature of the Zig build")
class Uninstall(StorageFixture):
    def setUp(self):
        super().setUp()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = "/usr/bin:/bin"
        self.installs, self.modules = [], []
        for target in ("x86_64/amd/zen2", "x86_64/amd/zen4"):
            base = self.prefix / "versions" / "2026.06" / "software" / "linux" / target
            install = base / "software" / "pigz" / "2.8-GCCcore-15.2.0"
            (install / "bin").mkdir(parents=True)
            (install / "bin" / "pigz").write_text("binary\n")
            (install / "easybuild").mkdir()
            (install / "easybuild" / "pigz.log").write_text("log\n")
            module = base / "modules" / "all" / "pigz" / "2.8-GCCcore-15.2.0.lua"
            module.parent.mkdir(parents=True)
            module.write_text("-- module\n")
            # Read-only, as EasyBuild leaves it.
            for path in sorted(install.rglob("*"), reverse=True) + [install]:
                path.chmod(0o555 if path.is_dir() else 0o444)
            self.installs.append(install)
            self.modules.append(module)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, SLURM_JOB_ID="", **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_dry_run_lists_every_target(self):
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(run.returncode, 0, run.stderr)
        for path in self.installs + self.modules:
            self.assertIn(str(path), run.stdout)
            self.assertTrue(path.exists())

    def test_without_rtrash_nothing_goes_unless_asked(self):
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"])
        self.assertEqual(run.returncode, 1)
        self.assertIn("rtrash is not installed; nothing removed", run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))
        # The emptied NAME directories go too.
        self.assertFalse(self.installs[0].parent.exists())

    def test_clean_trash_none_is_what_keeps_them_with_rtrash_there(self):
        (self.bin / "rtrash").write_text(RTRASH)
        (self.bin / "rtrash").chmod(0o755)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], PATH=f"{self.bin}:/usr/bin:/bin",
                            EB_LOCAL_CLEAN_TRASH="none")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("clean.trash is none [environment EB_LOCAL_CLEAN_TRASH]; nothing removed. "
                      "Pass --delete to delete for good, or set clean.trash to auto or rtrash.", run.stderr)
        self.assertNotIn("rtrash is not installed", run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        self.assertFalse((self.root / "trashed").exists())

    def test_with_rtrash_both_targets_go_to_the_trash(self):
        (self.bin / "rtrash").write_text(RTRASH)
        (self.bin / "rtrash").chmod(0o755)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], PATH=f"{self.bin}:/usr/bin:/bin")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        trashed = (self.root / "trashed").read_text().splitlines()
        self.assertEqual(sorted(trashed), sorted(str(p) for p in self.installs + self.modules))
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def class_link(self, module, moduleclass, target):
        link = module.parent.parent.parent / moduleclass / "pigz" / module.name
        link.parent.mkdir(parents=True)
        link.symlink_to(target)
        return link

    def test_the_class_links_to_a_module_file_go_with_it(self):
        # EasyBuild links modules/<class>/NAME/VERSION.lua to the module file
        # in modules/all by its absolute path; a relative link counts too,
        # and a link to another file stays.
        links = [self.class_link(m, "tools", m) for m in self.modules]
        links.append(self.class_link(self.modules[0], "lib", Path("..") / ".." / "all" / "pigz" / self.modules[0].name))
        other = self.class_link(self.modules[0], "devel", self.root / "elsewhere.lua")
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for link in links:
            self.assertIn(str(link), run.stdout)
        self.assertNotIn(str(other), run.stdout)
        (self.bin / "rtrash").write_text(RTRASH)
        (self.bin / "rtrash").chmod(0o755)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], PATH=f"{self.bin}:/usr/bin:/bin")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        trashed = (self.root / "trashed").read_text().splitlines()
        self.assertEqual(sorted(trashed), sorted(str(p) for p in self.installs + self.modules + links))
        for link in links:
            self.assertFalse(os.path.lexists(link), link)
            # The NAME directory it leaves empty goes too.
            self.assertFalse(link.parent.exists(), link.parent)
        self.assertTrue(os.path.lexists(other))

    def test_a_link_an_earlier_uninstall_left_dangling_goes(self):
        link = self.class_link(self.modules[0], "tools", self.modules[0])
        for path in self.installs:
            subprocess.run(["chmod", "-R", "u+w", str(path)], check=True)
            subprocess.run(["rm", "-rf", str(path)], check=True)
        for path in self.modules:
            path.unlink()
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse(os.path.lexists(link))

    def trash(self):
        (self.bin / "rtrash").write_text(TRASH)
        (self.bin / "rtrash").chmod(0o755)
        return {"PATH": f"{self.bin}:/usr/bin:/bin", "XDG_DATA_HOME": str(self.root / "xdg")}

    def tree(self, top):
        return [top, *(p for p in top.rglob("*") if not p.is_symlink())]

    def test_the_trash_keeps_the_files_read_only(self):
        # rtrash renames a directory, copies one across file systems and
        # empties the trash only when the directories are writable; the
        # files need not be, and keep EasyBuild's modes.
        env = self.trash()
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        trashed = [p for p in (self.root / "xdg" / "Trash" / "files").iterdir() if p.is_dir()]
        self.assertEqual(len(trashed), 2)
        for path in self.tree(trashed[0]) + self.tree(trashed[1]):
            mode = path.stat().st_mode
            if stat.S_ISDIR(mode):
                self.assertTrue(mode & stat.S_IWUSR, path)
            else:
                self.assertEqual(stat.S_IMODE(mode), 0o444, path)

    def test_restore_brings_every_target_back_read_only(self):
        outside = self.root / "outside"
        outside.mkdir()
        outside.chmod(0o755)
        self.installs[0].chmod(0o755)
        (self.installs[0] / "lib64").symlink_to(outside, target_is_directory=True)
        self.installs[0].chmod(0o555)
        env = self.trash()
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0", "--dry-run"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for path in self.installs + self.modules:
            self.assertIn(str(path), run.stdout)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        self.assertEqual(self.modules[0].read_text(), "-- module\n")
        self.assertEqual(list((self.root / "xdg" / "Trash" / "info").iterdir()), [])
        # Write permission for no one, as EasyBuild leaves an installation;
        # a symbolic link inside is not followed.
        for path in self.tree(self.installs[0]) + self.tree(self.installs[1]):
            self.assertEqual(path.stat().st_mode & 0o222, 0, path)
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o755)

    def test_restore_refusals(self):
        env = self.trash()
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("not in the trash", run.stderr)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        # Installed again since: restore replaces nothing, and brings back
        # nothing of the rest either.
        self.installs[1].mkdir(parents=True)
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn(str(self.installs[1]), run.stderr)
        self.assertFalse(self.installs[0].exists())
        self.installs[1].rmdir()
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], PATH="/usr/bin:/bin", XDG_DATA_HOME=env["XDG_DATA_HOME"])
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        for args in (["restore"], ["restore", "pigz"], ["restore", "../x/1"], ["restore", "pigz/2.8-GCCcore-15.2.0", "--delete"]):
            self.assertEqual(self.run_tool(args, **env).returncode, 2, args)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_restore_brings_back_a_class_link_after_its_module_file(self):
        # EasyBuild links modules/<class>/NAME/VERSION.lua to the module
        # file; in the trash with it, the link comes back after the file.
        env = self.trash()
        link = self.modules[0].parent.parent.parent / "tools" / "pigz" / self.modules[0].name
        link.parent.mkdir(parents=True)
        link.symlink_to(self.modules[0])
        subprocess.run([str(self.bin / "rtrash"), "put", "--", str(link)], env=env, check=True)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(os.readlink(link), str(self.modules[0]))
        self.assertLess(run.stdout.index(f"restored '{self.modules[0]}'"), run.stdout.index(f"restored '{link}'"))

    def test_restore_leaves_a_choice_between_two_copies_to_rtrash(self):
        env = self.trash()
        for _ in range(2):
            (self.installs[0] / "bin").mkdir(parents=True, exist_ok=True)
            self.modules[0].parent.mkdir(parents=True, exist_ok=True)
            self.modules[0].write_text("-- module\n")
            run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], **env)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn(f"rtrash restore {shlex.quote(str(self.installs[0]))}", run.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_a_refused_trash_leaves_the_module_files(self):
        # An rtrash that refuses the installations: the module files stay.
        (self.bin / "rtrash").write_text('#!/bin/sh\necho refused >&2\nexit 1\n')
        (self.bin / "rtrash").chmod(0o755)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], PATH=f"{self.bin}:/usr/bin:/bin")
        self.assertNotEqual(run.returncode, 0)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_refusals(self):
        self.assertEqual(self.run_tool(["uninstall", "absent/1.0"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall", "pigz"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall", "pigz/2.8;rm -rf ~"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall", "../x/1"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall"]).returncode, 2)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def dependent(self, text):
        module = self.modules[0].parent.parent / "parallel-gzip-user" / "1.0.lua"
        module.parent.mkdir()
        module.write_text(text)
        return module

    def test_a_module_another_loads_stays(self):
        dependent = self.dependent('depends_on("pigz/2.8-GCCcore-15.2.0")\n')
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn(str(dependent), run.stderr)
        self.assertIn("same command", run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(run.returncode, 2)
        # Named together, both go.
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "parallel-gzip-user/1.0", "--delete"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse(dependent.exists())
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_a_guarded_load_counts_and_a_mention_does_not(self):
        dependent = self.dependent('if not ( isloaded("pigz/2.8-GCCcore-15.2.0") ) then\n'
                                   '    load("pigz/2.8-GCCcore-15.2.0")\nend\n')
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(run.returncode, 2, run.stdout)
        dependent.write_text('help([==[ works well with pigz/2.8-GCCcore-15.2.0 ]==])\n')
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_a_symlinked_tree_is_not_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep\n")
        versions = self.prefix / "versions"
        for path in sorted(versions.rglob("*"), reverse=True):
            os.chmod(path, 0o755 if path.is_dir() else 0o644)
        os.rename(versions, self.root / "real-versions")
        versions.symlink_to(self.root / "real-versions", target_is_directory=True)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertTrue((self.root / "real-versions").exists())


if __name__ == "__main__":
    unittest.main()
