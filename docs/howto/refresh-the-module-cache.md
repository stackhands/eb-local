<!-- Generated from docs/orgmode/howto/refresh-the-module-cache.org by docs/export.el; edit that file. -->

# Refresh the Lmod spider cache

After a site install, `module avail` and `module spider` show the new module only when Lmod's spider cache names it.
Lmod ignores a cache whose timestamp file is newer than `spiderT.lua`.
This page writes both, with the timestamp one second older.

## Before you start

-   The module directories the site adds to `MODULEPATH`, as absolute paths.
-   A directory Lmod's configuration reads as its cache directory, and the timestamp file that configuration names.
-   Lmod's `spider` program on `PATH`, or its path for `--spider`.

`lmod-cache` does not read the site file, and it does not change a module.

## Steps

1.  Write the cache. `--modulepath` is the same colon-separated list a user would have on `MODULEPATH`:

    ```bash
    eb-local lmod-cache \
      --modulepath /opt/site/modules/all:/opt/site/modules/zen4 \
      --cache-dir /opt/site/.lmod/cache \
      --timestamp /opt/site/.lmod/system.txt
    ```

    The command prints:

    ```text
    wrote /opt/site/.lmod/cache/spiderT.lua; /opt/site/.lmod/system.txt is older than it
    ```

    `spiderT.lua` is what `spider -o spiderT` wrote. The timestamp file's modification time is one second earlier, which is the mark Lmod uses to trust the cache.
2.  Point Lmod at those two paths, in the `lmodrc.lua` the site already loads. The cache directory is the directory that now holds `spiderT.lua`, and the timestamp is the file named above.
3.  Run it again after the next install. A build pipeline can use the same command as its cache command, with the paths written out. `[caches].command` is not a shell, so the paths are absolute.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `lmod-cache needs --modulepath, --cache-dir and --timestamp` | One of the three is missing. | Pass all three. |
| `--cache-dir DIR is not an absolute path` | `DIR` is relative, as is a module directory or the timestamp. | Pass absolute paths. The cache is read later from another working directory. |
| `cannot run spider: FileNotFound. Install Lmod and put spider on PATH, as https://lmod.readthedocs.io/en/latest/030_installing.html describes, or pass --spider with its path` | `spider` is not on `PATH`. | Install Lmod, or pass `--spider` with the program's path. |
| `spider exited N; the cache was not changed` | `spider` failed. The previous `spiderT.lua` and timestamp are untouched. | Read the lines above that one, fix the module directories, and run it again. |

## Next steps

-   [Find what is wrong](find-what-is-wrong.md) when a module still does not load.
-   [Lmod's system spider cache](https://lmod.readthedocs.io/en/latest/130_spider_cache.html) for the timestamp rule this command follows.
