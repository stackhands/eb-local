#!/usr/bin/env python3
"""eb-local uninstall and restore, through the command line of the Zig build.

An installation made by EasyBuild through EESSI-extend is read-only, so
rm -rf cannot remove it; uninstall makes it writable and removes it, for
every CPU target, with rtrash or, asked, for good. restore brings back what
went to the trash, read-only again.
"""
import json
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

    def keep_logs(self):
        """An eb-keep-logs that records its argv and exits CONTROL_USED_STATUS."""
        (self.bin / "eb-keep-logs").write_text("#!" + sys.executable + "\n" + r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["CONTROL_ROOT"])
(root / "used.json").write_text(json.dumps(sys.argv))
note = os.environ.get("CONTROL_USED_NOTE", "")
if note:
    sys.stderr.write(note + "\n")
    sys.stdout.write("hits\n")
sys.exit(int(os.environ["CONTROL_USED_STATUS"]))
''')
        (self.bin / "eb-keep-logs").chmod(0o755)

    def on_path(self, **extra):
        extra.setdefault("CONTROL_USED_STATUS", "0")
        return dict(PATH=f"{self.bin}:/usr/bin:/bin", **extra)

    def used_argv(self):
        return json.loads((self.root / "used.json").read_text())

    def test_without_usage_log_uninstall_does_not_ask(self):
        self.keep_logs()
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"], **self.on_path())
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse((self.root / "used.json").exists())
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_usage_log_clear_lets_uninstall_continue(self):
        self.keep_logs()
        log = self.root / "usage.json"
        log.write_text("{}\n")
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--usage-log", str(log), "--dry-run"],
                            **self.on_path())
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("dry run", run.stdout)
        self.assertEqual(self.used_argv()[1:], ["used", "--prefix", str(self.prefix), "--require-none", str(log)])
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", f"--usage-log={log}", "--delete"],
                            **self.on_path())
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_usage_log_exit_2_removes_nothing(self):
        self.keep_logs()
        log = self.root / "usage.json"
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--usage-log", str(log), "--dry-run", "--delete"],
                            **self.on_path(CONTROL_USED_STATUS="2", CONTROL_USED_NOTE="named in the log"))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn(f"eb-keep-logs used --prefix {self.prefix} --require-none exited 2; nothing was removed.", run.stderr)
        self.assertIn("  named in the log", run.stderr)
        self.assertIn("  hits", run.stderr)
        self.assertNotIn("dry run", run.stdout)
        self.assertNotIn(str(self.installs[0]), run.stdout)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_a_missing_eb_keep_logs_or_another_status_removes_nothing(self):
        log = self.root / "usage.json"
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--usage-log", str(log), "--delete"])
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("eb-keep-logs is not on PATH, so the usage log cannot be read; nothing was removed.", run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        self.keep_logs()
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--usage-log", str(log), "--delete"],
                            **self.on_path(CONTROL_USED_STATUS="7"))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("eb-keep-logs used exited 7; nothing was removed.", run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_a_dependent_is_refused_before_the_usage_log(self):
        self.keep_logs()
        self.dependent('depends_on("pigz/2.8-GCCcore-15.2.0")\n')
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--usage-log", str(self.root / "usage.json"), "--delete"],
                            **self.on_path(CONTROL_USED_STATUS="0"))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("same command", run.stderr)
        self.assertFalse((self.root / "used.json").exists())
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_usage_log_is_one_option_of_uninstall(self):
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--usage-log", "a", "--usage-log", "b"])
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertIn("uninstall takes one --usage-log", run.stderr)
        run = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0", "--usage-log", "a"])
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertIn("restore does not know '--usage-log'", run.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_default_uninstall_outputs_and_statuses_are_unchanged_raw_bytes(self):
        # Remove the second target so filesystem walk order is single-entry deterministic.
        subprocess.run(["chmod", "-R", "u+w", str(self.installs[1])], check=True)
        subprocess.run(["rm", "-rf", str(self.installs[1])], check=True)
        self.modules[1].unlink()

        def run_raw(args):
            argv, env = binary.command(self.script, args, dict(self.env, SLURM_JOB_ID=""))
            return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)

        listed = f"  {self.installs[0]}/\n  {self.modules[0]}\n".encode()
        dry = run_raw(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(
            (dry.returncode, dry.stdout, dry.stderr),
            (0, listed + b"eb-local: dry run, nothing removed\n", b""),
        )

        no_rtrash = run_raw(["uninstall", "pigz/2.8-GCCcore-15.2.0"])
        self.assertEqual(
            (no_rtrash.returncode, no_rtrash.stdout, no_rtrash.stderr),
            (
                1,
                listed,
                b"eb-local: rtrash is not installed; nothing removed. Install rtrash, or pass --delete to delete for good.\n",
            ),
        )

        deleted = run_raw(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(
            (deleted.returncode, deleted.stdout, deleted.stderr),
            (0, listed + b"eb-local: deleted 1 installation(s) and 1 module file(s)\n", b""),
        )

        missing = run_raw(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(
            (missing.returncode, missing.stdout, missing.stderr),
            (2, b"", f"eb-local: pigz/2.8-GCCcore-15.2.0 is not installed in {self.prefix}\n".encode()),
        )

    def test_target_limits_uninstall_and_dependents_check_to_one_cpu_target(self):
        # Dependent module exists only in zen2 (self.modules[0]'s tree).
        self.dependent('depends_on("pigz/2.8-GCCcore-15.2.0")\n')
        zen4_link = self.class_link(self.modules[1], "tools", self.modules[1])

        blocked = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target", "zen2", "--delete"])
        self.assertEqual(blocked.returncode, 2, blocked.stdout + blocked.stderr)
        self.assertIn("same command", blocked.stderr)
        self.assertTrue(self.installs[0].exists() and self.installs[1].exists())

        dry = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target=x86_64/amd/zen4", "--dry-run"])
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn(str(self.installs[1]), dry.stdout)
        self.assertIn(str(self.modules[1]), dry.stdout)
        self.assertIn(str(zen4_link), dry.stdout)
        self.assertNotIn(str(self.installs[0]), dry.stdout)

        removed = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target", "zen4", "--delete"])
        self.assertEqual(removed.returncode, 0, removed.stdout + removed.stderr)
        self.assertFalse(self.installs[1].exists())
        self.assertFalse(self.modules[1].exists())
        self.assertFalse(os.path.lexists(zen4_link))
        self.assertTrue(self.installs[0].exists())
        self.assertTrue(self.modules[0].exists())

        absent = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target", "zen4", "--delete"])
        self.assertEqual(absent.returncode, 2)
        self.assertIn("not installed for target zen4", absent.stderr)

        dup = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target", "zen2", "--target", "zen4"])
        self.assertEqual(dup.returncode, 2)
        self.assertIn("uninstall takes one --target", dup.stderr)

        restore_flag = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0", "--target", "zen4"])
        self.assertEqual(restore_flag.returncode, 2)
        self.assertIn("restore does not know '--target'", restore_flag.stderr)

    def test_ambiguous_short_target_refuses_and_lists_candidate_paths(self):
        # Add a second CPU family tree whose basename is also zen4.
        other_tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "other" / "zen4"
        other_install = other_tree / "software" / "pigz" / "2.8-GCCcore-15.2.0"
        (other_install / "bin").mkdir(parents=True)
        (other_install / "bin" / "pigz").write_text("binary\n")
        other_module = other_tree / "modules" / "all" / "pigz" / "2.8-GCCcore-15.2.0.lua"
        other_module.parent.mkdir(parents=True)
        other_module.write_text("-- module\n")

        ambiguous = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target", "zen4", "--delete"])
        self.assertEqual(ambiguous.returncode, 2, ambiguous.stdout + ambiguous.stderr)
        self.assertIn("more than one CPU tree", ambiguous.stderr)
        amd_tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        self.assertIn(str(amd_tree), ambiguous.stderr)
        self.assertIn(str(other_tree), ambiguous.stderr)
        self.assertTrue(self.installs[1].exists())
        self.assertTrue(other_install.exists())

        # Naming the full target selects only that tree.
        exact = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--target", "x86_64/other/zen4", "--delete"])
        self.assertEqual(exact.returncode, 0, exact.stdout + exact.stderr)
        self.assertFalse(other_install.exists())
        self.assertFalse(other_module.exists())
        self.assertTrue(self.installs[1].exists())
        self.assertTrue(self.modules[1].exists())

    def test_duplicate_module_arguments_uninstall_and_restore_cleanly(self):
        env = self.trash()
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))
        restored = self.run_tool(["restore", "pigz/2.8-GCCcore-15.2.0"], **env)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

        delete_dup = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(delete_dup.returncode, 0, delete_dup.stdout + delete_dup.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_single_quoted_dependents_block_uninstall(self):
        dep = self.dependent("depends_on('pigz/2.8-GCCcore-15.2.0')\n")
        for stmt in ("depends_on('pigz/2.8-GCCcore-15.2.0')\n", "load('pigz/2.8-GCCcore-15.2.0')\n"):
            with self.subTest(stmt=stmt.strip()):
                dep.write_text(stmt)
                blocked = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
                self.assertEqual(blocked.returncode, 2, blocked.stdout + blocked.stderr)
                self.assertIn("same command", blocked.stderr)
                self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_uninstall_delete_permission_error_names_path_and_errno(self):
        mod_parent = self.modules[0].parent
        mod_parent.chmod(0o555)
        try:
            got = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            self.assertIn(str(self.modules[0]), got.stderr)
            self.assertIn("[Errno 13] Permission denied", got.stderr)
        finally:
            mod_parent.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
