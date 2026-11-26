<!-- Generated from docs/orgmode/howto/set-site-defaults.org by docs/export.el; edit that file. -->

# Set a site's EasyBuild defaults and default prefix

A site can give every user EasyBuild settings of its own when EESSI-extend loads, with an Lmod hook, and needs no eb-local setting for them.
A default install prefix other than `$HOME/eessi` cannot come from that hook: it goes into the users' environment before EESSI-extend loads, and into eb-local's site file.
These steps set EasyBuild's source and build paths with a hook, then make `$HOME/.local/eessi` the default prefix for EESSI-extend and eb-local alike.
[Where EESSI-extend installs](../explanation/install-variables.md) says why an install path or a prefix cannot come from the hook.

## Before you start

-   Write access to the directory that `/cvmfs/software.eessi.io/host_injections` links to, here `/opt/eessi`.
-   eb-local's site file, as [Write the site file for a cluster](write-a-site-file.md) describes, for the default prefix.

## Set EasyBuild paths with an Lmod hook

1.  Write the hook to `/cvmfs/software.eessi.io/host_injections/2026.06/.lmod/SitePackage.lua`, readable by everyone:

    ```lua
    local hook = require("Hook")

    -- EasyBuild's source and build paths, set as EESSI-extend loads.
    local function site_load_hook(t)
        if t.modFullName:find("^EESSI%-extend/") then
            local home, user = os.getenv("HOME"), os.getenv("USER")
            setenv("EASYBUILD_SOURCEPATH", pathJoin(home, ".local/easybuild/sources"))
            setenv("EASYBUILD_BUILDPATH", pathJoin("/tmp", user, "easybuild-build"))
        end
    end

    hook.register("load", function(t)
        eessi_load_hook(t)
        site_load_hook(t)
    end)
    ```

    EESSI's own `SitePackage.lua` registers its load hook, `eessi_load_hook`, and then runs this file.
    Lmod keeps one load hook, so this one calls EESSI's first.
    It runs for the modules loaded once EESSI is, and not for the `EESSI` module itself: that module sets `LMOD_PACKAGE_PATH`, through which Lmod finds EESSI's `SitePackage.lua` and so this file, and neither is in effect for the command that loads it.

2.  Load EESSI-extend by hand, and read the paths:

    ```bash
    source /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
    module load EESSI-extend/2026.06-easybuild
    echo "$EASYBUILD_SOURCEPATH $EASYBUILD_BUILDPATH"
    ```

    After the messages of EESSI and EESSI-extend, the last line has the two paths:

    ```text
    ...
    /home/alice/.local/easybuild/sources /tmp/alice/easybuild-build
    ```

    Lmod undoes only what a module file sets, so the two stay set after `module unload EESSI-extend/2026.06-easybuild`.

3.  Check that `eb-local eb`, which loads EESSI-extend the same way, gives EasyBuild the hook's paths:

    ```bash
    eb-local eb -- --show-config 2>/dev/null | grep -E '^(buildpath|sourcepath) '
    ```

    ```text
    buildpath                                (E) = /tmp/alice/easybuild-build
    sourcepath                               (D) = /home/alice/.local/easybuild/sources
    ```

A build with a site file puts its own paths back after EESSI-extend loads: its workspace in the allocation's node-local mount, and `.eb-local/sources` in the prefix.
In an allocation:

```bash
eb-local pigz-2.8-GCCcore-15.2.0.eb --show-config 2>/dev/null | grep -E '^(buildpath|sourcepath) '
```

```text
buildpath                                (E) = /local/alice.39/eb-local.P6nUglgY/build
sourcepath                               (E) = /home/alice/eessi/.eb-local/sources
```

## Give every user another default prefix

1.  Export the prefix in a login script, such as `/etc/profile.d/eessi-user-install.sh`, for a shell where no install variable is set:

    ```sh
    # The site's default prefix for EESSI-extend, set before any module loads.
    # eb-local's site file sets prefix to the same directory.
    if [ -z "${EESSI_USER_INSTALL+x}${EESSI_PROJECT_INSTALL+x}${EESSI_SITE_INSTALL+x}${EESSI_CVMFS_INSTALL+x}" ]; then
        export EESSI_USER_INSTALL="$HOME/.local/eessi"
        [ -d "$EESSI_USER_INSTALL" ] || mkdir -p -m 700 "$EESSI_USER_INSTALL"
    fi
    ```

    EESSI-extend refuses to load for a user directory that does not exist, so the script creates it, private, as eb-local creates a prefix.

2.  Set the same prefix in eb-local's site file, before its first table:

    ```toml
    prefix = "~/.local/eessi"
    ```

    eb-local then builds there, and `eb-local env` loads the modules from there.

## Check that it worked

In a new login shell:

```bash
eb-local doctor
```

```text
ok   eb-local 3.5.0
ok   site file /usr/local/bin/config.toml
ok   builds use the allocation's own xfs mount /local/%u.%j
ok   installs go to /home/alice/.local/eessi: a user install, prefix from site /usr/local/bin/config.toml:9
ok   EESSI_USER_INSTALL names your prefix, as eb-local env sets it
ok   no other EESSI or EasyBuild install variable is set in this shell
ok   `eb-local eb` sources /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
ok   `eb-local eb` makes a user install: EESSI_USER_INSTALL=/home/alice/.local/eessi
info not in a Slurm job; builds need one on the node type that will run the software, for example: salloc -p cpu -n 16 -t 02:00:00
info EESSI is not loaded in this shell; eval "$(eb-local env)" loads it with your modules
info eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI detects
info no module command in this shell; builds source /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
ok   rtrash is on PATH: clean and uninstall move files to the trash

Nothing above stops a build.
```

The fourth and fifth lines name the new prefix, and say that `EESSI_USER_INSTALL` names it too.
EESSI-extend loaded by hand says where it installs:

```bash
source /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
module load EESSI-extend/2026.06-easybuild
```

```text
Module for EESSI/2026.06 loaded successfully
EESSI has selected x86_64/intel/sapphirerapids as the compatible CPU target for EESSI/2026.06
EESSI did not identify an accelerator on the system
(for debug information when loading the EESSI module, set the environment variable EESSI_MODULE_DEBUG_INIT)
-- Using /tmp/$USER as a temporary working directory for installations, you can
override this by setting the environment variable WORKING_DIR and reloading the
module (e.g., /dev/shm is a common option)
Configuring for use of EESSI_USER_INSTALL under /home/alice/.local/eessi
-- To create installations for EESSI, you _must_ have write permissions to
/home/alice/.local/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids
-- You may wish to configure a sources directory for EasyBuild (for example,
via setting the environment variable EASYBUILD_SOURCEPATH) to allow you to
reuse existing sources for packages.
```

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local: EESSI-extend set the install path to DIR, outside PREFIX, where a user install goes; nothing was built.` | The hook sets `EASYBUILD_INSTALLPATH`, `EASYBUILD_INSTALLPATH_SOFTWARE` or `EASYBUILD_INSTALLPATH_MODULES`; `eb-local eb` exits 2 before `eb` runs. | Take the install path out of the hook. |
| `eb-local: loading EESSI-extend/2026.06-easybuild set the install path to DIR, outside PREFIX/versions, the tree eb-local checked; nothing was built.` | The same, in a build. | Take the install path out of the hook. |
| `eb-local: loading EESSI-extend/2026.06-easybuild set EESSI_USER_INSTALL=DIR; this build still installs into PREFIX, but` | The hook sets an install variable, which only the next load in that shell uses. | Take it out of the hook, and set a default prefix as above. |
| `Lmod has detected the following error: The location of EESSI_USER_INSTALL (DIR) does not exist or is not a folder` | EESSI-extend, loaded by hand, for a prefix that does not exist yet. | Create it, as the login script does; eb-local creates it at the first build. |
| `warn EESSI_USER_INSTALL=DIR is set in this shell; eb-local builds clear it, but EESSI-extend or eb run by hand would use it` | The login script and `prefix` name different directories. | Make them the same. |

## Related

-   [Where EESSI-extend installs](../explanation/install-variables.md)
-   [Write the site file for a cluster](write-a-site-file.md)
-   [Run EasyBuild through EESSI-extend without a site file](eb-without-a-site-file.md)
-   [The configuration files](../reference/configuration.md), for `prefix`
