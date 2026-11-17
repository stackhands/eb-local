<!-- Generated from docs/orgmode/howto/write-a-site-file.org by docs/export.el; edit that file. -->

# Write the site file for a cluster

The site file tells eb-local where each Slurm job's node-local disk is mounted, which parallel file systems builds must avoid, and which `salloc` line to suggest outside a job.
A build with EasyBuild refuses to start without one; `eb-local env`, `eb-local dev` and `eb-local eb` work without it.
These steps write the site file from a template, install it beside the program, and check it on a compute node.

## Before you start

-   eb-local installed in one place for every user, as [Install eb-local](install.md) describes, and a shell as root or as the account that owns the program.
-   How Slurm mounts a job's node-local disk: the directory the mounts are in, the name of each job's mount in it, and the file system type.
    Each job's mount must be a mount of its own, owned by the job's user, with the job id in its name.
-   The paths of the parallel file systems the nodes mount, such as `/scratch`.

## Write the file

1.  List the templates eb-local carries, and their placeholders:

    ```bash
    eb-local site list
    ```

    ```text
    slurm        placeholders: node_local_root, node_local_mount, node_local_fstype, shared_scratch, partition
    ```

    `slurm` is for any Slurm cluster whose jobs get a node-local disk.

2.  Print the file with your values:

    ```bash
    eb-local site show slurm --set node_local_root=/local --set shared_scratch=/scratch
    ```

    ```text
    # eb-local site file for a Slurm cluster whose jobs get a node-local disk.
    #   eb-local site install slurm --set node_local_root=/local \
    #       --set shared_scratch=/scratch [--set node_local_mount=%j] \
    #       [--set node_local_fstype=ext4] [--set partition=cpu]
    # Each allocation's mount must be <node_local_root>/<node_local_mount>, with
    # %u the user and %j the job id, owned by the user; shared_scratch is the
    # parallel file system builds must avoid.

    [storage]
    node_local_root = "/local"
    node_local_mount = "%u.%j"
    node_local_fstype = "xfs"
    shared_scratch = ["/scratch"]

    [build]
    allocation_hint = "salloc -p cpu -n 16 -t 02:00:00"
    # site_toolchains = ["intel/2026.1"]

    # Users name their own vault for nimvault secrets in ~/.config/eb-local/config.toml:
    #   [nimvault]
    #   vault = "~/vault"
    ```

    `node_local_root` and `shared_scratch` have no default, so each needs a `--set`.
    The others take their default unless set: `node_local_mount` is `%u.%j`, the user name and the job id, so job 4242 of the user `alice` has `/local/alice.4242`; `node_local_fstype` is `xfs`; `partition`, the partition in `build.allocation_hint`, is `cpu`.
    `site show` checks the file as eb-local checks a site file it reads, and writes nothing.

3.  Install it:

    ```bash
    eb-local site install slurm --set node_local_root=/local --set shared_scratch=/scratch
    ```

    ```text
    wrote /usr/local/bin/config.toml from template slurm; eb-local config shows what it sets
    ```

    `site install` writes `config.toml` beside the program, mode 644, or the file that `--to FILE` names.
    It writes the file only when it loads as a site file, replaces an existing file only with `--force`, and never writes through a symbolic link.

4.  Add what the template has no placeholder for by editing the file: another parallel file system in `shared_scratch`, `build.site_toolchains`, `[build.node_types]` or `[eessi]`.
    [The configuration files](../reference/configuration.md) lists every key, and the order in which eb-local looks for the site file.
    `eb-local config` reads the file again, and names the file and line of a key it refuses.

## Keep a template of your own

A site that installs eb-local on more than one cluster, or again for each release, can keep its own template in a repository of its own.
A template is a site file with `{{name}}` placeholders, which `--set name=VALUE` must fill, and `{{name:default}}` ones, which take the default unless set.
`examples/sites/example.toml` in eb-local's repository is a worked example, for a site that does not exist.
Copy it, change it, and give its path, with a slash, in place of `slurm`:

```bash
eb-local site show ./site.toml --set partition=gpu
eb-local site install ./site.toml --set partition=gpu
```

eb-local takes a name with a slash as a template file, and a name without one as a template it carries.
It reads a template file only when it is a regular file, not a symbolic link, and not writable by group or others.

## Check that it worked

As a user, print the configuration:

```bash
eb-local config
```

The storage settings and `build.allocation_hint` name the site file and the line that sets them:

```text
build.allocation_hint        salloc -p cpu -n 16 -t 02:00:00   [site /usr/local/bin/config.toml:16]
storage.node_local_root      /local   [site /usr/local/bin/config.toml:10]
storage.node_local_mount     %u.%j   [site /usr/local/bin/config.toml:11]
storage.node_local_fstype    xfs   [site /usr/local/bin/config.toml:12]
storage.shared_scratch       /scratch   [site /usr/local/bin/config.toml:13]
```

Then check the mount in a job, where a build would make its workspace:

```bash
salloc -p cpu -n 1 -t 00:05:00 srun eb-local doctor
```

```text
ok   eb-local 3.1.0
ok   site file /usr/local/bin/config.toml
ok   builds use the allocation's own xfs mount /local/%u.%j
ok   installs go to /home/alice/eessi: a user install, prefix from default
ok   no other EESSI or EasyBuild install variable is set in this shell
ok   `eb-local eb` sources /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
ok   `eb-local eb` makes a user install into the module's default, $HOME/eessi
ok   Slurm job 6: build space /local/alice.6
info EESSI is not loaded in this shell; eval "$(eb-local env)" loads it with your modules
info eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI detects
warn your modules are not on MODULEPATH in this shell; eval "$(eb-local env)"
info no module command in this shell; builds, env and dev source /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
ok   rtrash is on PATH: clean and uninstall move files to the trash

Nothing above stops a build.
```

The `Slurm job` line shows the job's mount, which passed every check a build makes.
Outside a job, `doctor` says `info not in a Slurm job` in its place, and does not check the mount.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local: /usr/local/bin/config.toml exists; --force replaces it` | A site file is there already. | Compare it with what `site show` prints, then install again with `--force`. |
| `eb-local: template slurm needs --set node_local_root=VALUE and --set shared_scratch=VALUE` | Every placeholder with no default is named, in the order the template writes them. | Add each `--set`. `eb-local site list` prints the names. |
| `eb-local: template slurm has no placeholder NAME (it has: ...)` | `--set` names a placeholder the template does not have. | Use a name from the list. |
| `eb-local: --set NAME: the value must be non-empty, without quotes, backslashes or control characters` | Each value goes inside a TOML string. | Give a value without them. |
| `eb-local: template slurm:10: storage.node_local_root must be one absolute path without a trailing slash` | The value on line 10 of the rendered file is not a path from `/`. | Give the absolute path. |
| `eb-local: cannot write FILE: refusing to replace a symlink: FILE` | `FILE` is a symbolic link. | Name the file it leads to with `--to`. |
| `eb-local: FILE is writable by group or others and is not used; chmod go-w it` | The template file, or the installed site file, is writable by group or others. | Run `chmod go-w` on it. |
| `eb-local: FILE:LINE: [storage] is a site setting; a user file or a profile cannot change it` | The file that `--config` or `EB_LOCAL_CONFIG` names belongs to a user other than root or the program's owner, so eb-local reads it as that user's file. | Make root or the program's owner own it. |
| `FAIL Slurm job N: the node-local mount MOUNT does not exist; builds refuse it.` | `node_local_root` and `node_local_mount` do not name the job's mount. | Set them to where Slurm mounts the job's node-local disk. |
| `FAIL Slurm job N: the node-local mount MOUNT is on TYPE, not FSTYPE; builds refuse it.` | `node_local_fstype` is not the file system of the job's mount. | Set it to `TYPE` when that is the file system of the nodes' disks. |

[Refusals](../reference/refusals.md) lists every check of the mount.

## Related

-   [Install eb-local](install.md)
-   [Set a site's EasyBuild defaults and default prefix](set-site-defaults.md)
-   [The configuration files](../reference/configuration.md)
-   [The eb-local command](../reference/cli.md)
-   [Refusals](../reference/refusals.md)
