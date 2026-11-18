<!-- Generated from docs/orgmode/howto/clean-up.org by docs/export.el; edit that file. -->

# Clean up after builds, and remove what you installed

`eb-local clean` removes what builds leave in your prefix: old build logs, downloaded source archives, and the workspaces of builds that failed.
`eb-local uninstall` removes software you installed, for every CPU target, and `eb-local restore` brings it back.
With rtrash on `PATH`, files go to the trash, not away for good.

## Before you start

-   [rtrash](https://github.com/HaoZeke/rtrash) on `PATH`; `eb-local doctor` then says `ok   rtrash is on PATH: clean and uninstall move files to the trash`.
    Without it, `clean` and `uninstall` remove nothing unless you pass `--delete`, which deletes for good.
-   For what you built for a project, the same commands with `--project DIR`.

## Remove old logs and downloaded sources

1.  See what `clean` would remove:

    ```bash
    eb-local clean --dry-run
    ```

    ```text
    eb-local: nothing to clean in /home/alice/eessi
    ```

    By default `clean` takes the build logs in `.eb-local/logs` more than `clean.logs_older_than_days` whole days old, 30 unless your configuration sets another number; `--logs-older-than DAYS` sets it for one run.
    EasyBuild removes the log of a build that succeeds from there and keeps a copy in the installation, so these are the logs of builds that failed.
    A directory among them, such as the `reprod_*` copy of a failed build's easyconfig, easyblocks and hooks, goes whole once neither it nor anything in it is newer than that.

2.  Add the source archives builds downloaded:

    ```bash
    eb-local clean --sources --dry-run
    ```

    ```text
      /home/alice/eessi/.eb-local/sources/p/pigz/pigz-2.8.tar.gz
    eb-local: dry run, nothing removed (1 item(s), 0 workspace(s))
    ```

3.  Remove them, with the same options and no `--dry-run`:

    ```bash
    eb-local clean --sources
    ```

    ```text
      /home/alice/eessi/.eb-local/sources/p/pigz/pigz-2.8.tar.gz
    eb-local: moved 1 item(s) to the trash (rtrash list, rtrash restore)
    ```

    `rtrash list` shows what is in the trash, and `rtrash restore PATH` brings one file back.
    Add `--json` to print a single JSON line describing the planned or removed paths for scripts.

## Remove the workspace of a failed build

A build that fails keeps its workspace in the allocation's node-local mount, and says so:

```text
eb-local: build workspace kept at /local/alice.23/eb-local.bGSoHPgR; it goes when the allocation ends,
  or now with: eb-local clean --workspaces --no-logs
```

1.  In the same allocation, see what would go:

    ```bash
    eb-local clean --workspaces --no-logs --dry-run
    ```

    ```text
      /local/alice.23/eb-local.bGSoHPgR/ (build workspace)
    eb-local: dry run, nothing removed (0 item(s), 1 workspace(s))
    ```

2.  Remove it:

    ```bash
    eb-local clean --workspaces --no-logs
    ```

    ```text
      /local/alice.23/eb-local.bGSoHPgR/ (build workspace)
    eb-local: removed 1 build workspace(s)
    ```

    A workspace is deleted, not moved to the trash: the node-local mount goes when the allocation ends.
    For a batch job that is still running, here job 24, run the command in that job from a login node:

    ```bash
    srun --jobid=24 --overlap eb-local clean --workspaces --no-logs
    ```

    ```text
      /local/alice.24/eb-local.kapHubdH/ (build workspace)
    eb-local: removed 1 build workspace(s)
    ```

## Remove software you installed

1.  See what `uninstall` would remove, for every CPU target you built the module for:

    ```bash
    eb-local uninstall pigz/2.8-GCCcore-15.2.0 --dry-run
    ```

    ```text
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/pigz/2.8-GCCcore-15.2.0/
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/all/pigz/2.8-GCCcore-15.2.0.lua
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/tools/pigz/2.8-GCCcore-15.2.0.lua
    eb-local: dry run, nothing removed
    ```

    It takes the installation, its module file in `modules/all`, and the link EasyBuild makes to that file from the module's class, here `modules/tools`.

2.  Remove it:

    ```bash
    eb-local uninstall pigz/2.8-GCCcore-15.2.0
    ```

    ```text
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/pigz/2.8-GCCcore-15.2.0/
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/all/pigz/2.8-GCCcore-15.2.0.lua
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/tools/pigz/2.8-GCCcore-15.2.0.lua
    eb-local: moved 1 installation(s) and 2 module file(s) to the trash (eb-local restore brings them back)
    ```

    EasyBuild leaves an installation read-only, so `rm -rf` fails on it; `uninstall` makes its directories writable first.
    When another module you installed loads the one you name, `uninstall` lists that module and removes nothing, as it would then fail to load; name both in one command to remove both.

3.  To leave it in place when a usage log names this prefix:

    ```bash
    eb-local uninstall pigz/2.8-GCCcore-15.2.0 --usage-log usage.json
    ```

    This runs `eb-keep-logs used --prefix PREFIX --require-none usage.json`, where PREFIX is the install prefix, and removes nothing when that command exits 2.
    eb-local does not read the log.
    Without `--usage-log`, uninstall does not ask.

4.  To bring it back:

    ```bash
    eb-local restore pigz/2.8-GCCcore-15.2.0
    ```

    ```text
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/pigz/2.8-GCCcore-15.2.0/
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/all/pigz/2.8-GCCcore-15.2.0.lua
      /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/tools/pigz/2.8-GCCcore-15.2.0.lua
    restored '/home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/pigz/2.8-GCCcore-15.2.0'
    restored '/home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/all/pigz/2.8-GCCcore-15.2.0.lua'
    restored '/home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/tools/pigz/2.8-GCCcore-15.2.0.lua'
    eb-local: restored 1 installation(s), read-only again, and 2 module file(s)
    ```

    `restore` brings back each path with `rtrash restore`, then takes write permission away from the installation, as EasyBuild left it.
    `rtrash restore` alone brings the installation back with its directories writable.

## Check that it worked

After `uninstall`, `eb-local list` no longer shows the module; here it was the only one:

```bash
eb-local list
```

```text
Nothing is installed in /home/alice/eessi.
```

After `restore`, it shows the module again.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `rtrash is not installed; nothing removed. Install rtrash, or pass --delete to delete for good.` | rtrash is not on `PATH`. | Install rtrash, or pass `--delete` to delete for good. |
| `clean.trash is none [environment EB_LOCAL_CLEAN_TRASH]; nothing removed.` | `clean.trash` is `none` where the brackets say. | Pass `--delete` to delete for good, or set `clean.trash` to `auto`. |
| `clean --workspaces works only inside the Slurm job that made the workspaces, and SLURM_JOB_ID is unset or empty; nothing was removed.` | You ran it outside that job. | Run it in the allocation, or with `srun --jobid=JOBID --overlap`; once the job ends, its node-local mount is gone. |
| `these installed modules load what you named; uninstall them in the same command, or keep it:` | Another module you installed loads the one you named. | Name it in the same command too, or keep both. |
| `eb-keep-logs used --prefix PREFIX --require-none exited 2; nothing was removed.` | `eb-keep-logs used --require-none` exited 2 for this prefix and the log. | Keep the installation, or run uninstall without `--usage-log` when that log should not gate it. |
| `eb-keep-logs is not on PATH, so the usage log cannot be read; nothing was removed.` | `--usage-log` was given and `eb-keep-logs` is not on `PATH`. | Install `eb-keep-logs`, or run uninstall without `--usage-log`. |
| `eb-keep-logs used exited N; nothing was removed.` | `eb-keep-logs used` exited with a status other than 0 or 2. | Read the lines `eb-keep-logs` printed, then run it again or drop `--usage-log`. |
| `pigz/2.8-GCCcore-15.2.0 is not in the trash for /home/alice/eessi` | Nothing of that module is in the trash for this prefix. | Check `rtrash list`, and the prefix with `eb-local config`; for a project's modules, add `--project DIR`. |
| `PATH is in the trash more than once; restore the one you want with: rtrash restore PATH` | You uninstalled the module twice, as after building it again. | Run `rtrash restore` on the installation and on each module file `rtrash list` shows, choosing the same time each time, then `chmod -R a-w` the installation. |
| `PATH exists; restore replaces nothing, so nothing was restored` | The module is installed again. | Keep it, or uninstall it first. |

## Related

-   [The eb-local command](../reference/cli.md): `clean`, `uninstall` and `restore`
-   [The configuration files](../reference/configuration.md): `clean.trash` and `clean.logs_older_than_days`
-   [Find what is wrong with a build or a module](find-what-is-wrong.md)
