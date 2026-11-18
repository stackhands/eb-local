<!-- Generated from docs/orgmode/explanation/secrets.org by docs/export.el; edit that file. -->

# What happens to a secret

A build that needs a credential, such as a licence server or a token for a private source mirror, gets it from a secret: a variable name, and where its value comes from.
This page says when eb-local reads a value, where the value goes, how the logs lose it afterwards, and what eb-local does not clean.
[The configuration files](../reference/configuration.md) lists the sources and the names a secret may have, and [Give a secret only to the builds that need it](../howto/scope-secrets.md) has the steps to choose which builds get which secrets.

## Why a secret names a source

Configuration files get copied, shared and kept in version control, and a site file is readable by every user.
So `[secrets]` holds where each value comes from, never the value:

```toml
[secrets]
LM_LICENSE_FILE = "nimvault:licences/flexlm"   # what nimvault get licences/flexlm prints
SOURCE_TOKEN = "file:~/.secrets/source-token"   # a file of yours, mode 600
MIRROR_PASSWORD = "env:MY_MIRROR_PASSWORD"      # a variable in eb-local's environment
```

A value written in place of a source is refused:

```text
eb-local: /home/alice/.config/eb-local/config.toml:2: secret SOURCE_TOKEN: a source is env:VAR, file:PATH or nimvault:ENTRY; a value is never written in a configuration file
```

The name is the variable that `eb` gets.
It cannot be `PATH`, a name that starts with `LD_`, `EESSI_` or `EASYBUILD_`, or another variable the build depends on, since a secret of that name would change which programs and libraries the build uses, or where it installs.

## When a value is read

A build reads the secrets it gets after its other checks pass, and before it makes its workspace or starts `eb`.
A source that cannot be read stops the build there, and the message names the secret and the reason:

```text
eb-local: secret SOURCE_TOKEN (env:MY_SOURCE_TOKEN) is empty
```

A build reads every secret it gets, whether or not `eb` uses it, so a secret that one kind of build needs can stop every other kind.
`build.secrets` prevents that: a build that does not get a secret does not read it.

`eb-local config --check` and `eb-local doctor` read every secret, to say which can be read.
`eb-local config` and `eb-local --explain` read none.
None of them shows a value:

```text
secrets (values are never shown)
  SOURCE_TOKEN               env:MY_SOURCE_TOKEN   ok
```

## Which builds get which secrets

Every build gets every secret, unless `build.secrets` names the ones it gets.
A secret defined once then serves every build, and a site or a user narrows that where some builds must not see it.
`eb-local --explain` says, for each secret, whether the build gets it:

```text
# SOURCE_TOKEN reaches eb's environment from env:MY_SOURCE_TOKEN; logs are cleaned of it afterwards.
```

For a build that does not get it, the line is:

```text
# SOURCE_TOKEN stays out of eb's environment and is not read: build.secrets [environment EB_LOCAL_BUILD_SECRETS] does not name it. MY_SOURCE_TOKEN, the variable it comes from, stays out too.
```

The variable an `env:` source names is in eb-local's own environment, which a build passes on to `eb`.
A build that does not get the secret removes that variable too.
Otherwise the value would reach `eb` under the variable's name, and the logs would not be cleaned of a value that eb-local never read.
A variable that a secret may not set, such as `PATH`, stays, since the build needs it.

## Where a value goes

A secret the build gets is in the environment of `eb`, under the secret's name.
So it is in the environment of every program the build runs: EasyBuild, configure scripts, compilers and test suites.
eb-local does not print it.
A program that writes its environment to a log puts the value there, and eb-local removes it afterwards, as the next section says.
A program that writes the value into a file it installs leaves it there: eb-local cleans logs, not installations.

## How the logs lose the value

After the build, eb-local rewrites the logs written during it, in `PREFIX/.eb-local/logs` and in each installation's `easybuild` directory, and says how many held a value:

```text
eb-local: removed secret values from 1 log file(s)
```

Each value, its base64 form and its percent-encoded form, in either hex case, becomes `<secret NAME removed by eb-local>`.
A build step that printed `token=$SOURCE_TOKEN` leaves this line in the installation's log:

```text
token=<secret SOURCE_TOKEN removed by eb-local>
```

A value that occurs in the words of that marker, as `removed` does, would be put back by the marker.
In that case every marker is `<redacted:N>` instead, with a number N whose text holds no value.
Where one value starts with another, the longer one is removed whole, so the shorter one does not leave the rest of it behind.

EasyBuild compresses the copy of its log in an installation, with `bzip2` under EESSI-extend.
eb-local decompresses a log that ends in `.bz2`, `.gz`, `.xz` or `.zst`, and compresses it again with `bzip2`, `gzip`, `xz` or `zstd` from `PATH`.
`PREFIX/.eb-local/logs` is private, mode 700, from before a build with secrets starts.

eb-local names what it cannot clean, for you to inspect before you share it.
A value shorter than 4 bytes is not removed, since a string that short occurs throughout a log by chance.
The build says so before it starts:

```text
eb-local: secret SOURCE_TOKEN is shorter than 4 bytes and is not removed from logs
```

A log that is too large to check, nested too deep to reach, or that cannot be decompressed, is named with the reason.

## A build that stops early

eb-local passes SIGINT, SIGTERM, SIGHUP and SIGQUIT on to EasyBuild, waits for it to exit, cleans the logs, and then dies from the same signal.
Waiting lets eb-local clean the lines that EasyBuild writes as it stops.
Dying from the signal stops a cancelled job's script there, instead of letting it run its next line.
A signal from the terminal, such as Ctrl-C, reaches EasyBuild directly.
A signal that eb-local ignores, as SIGHUP is ignored under `nohup`, stays ignored.
SIGKILL cannot be caught, so a build killed with it leaves its logs unchecked.

A build stopped with SIGTERM during its build step exits with status 143, 128 plus the signal's number, after these lines:

```text
eb-local: removed secret values from 2 log file(s)
eb-local: build workspace kept at /local/alice.41/eb-local.9N9heVqb; it goes when the allocation ends,
  or now with: eb-local clean --workspaces --no-logs
```

## What a kept workspace holds

A build that fails or is stopped keeps its workspace for you to look into, and eb-local does not clean it.
For the shell command that failed, or that was running when the build stopped, EasyBuild leaves `cmd.sh`, `env.sh` and `out.txt` in `tmp/eb-*/run-shell-cmd-output/` in the workspace.
When a command fails, EasyBuild names `out.txt`, its output, and `cmd.sh`, a script that runs the command again in an interactive shell.
`env.sh` holds the environment, with the value of each secret the build gets.
The workspace is yours alone, mode 700, on the node's own disk.
It goes when the allocation ends, or when `eb-local clean --workspaces --no-logs` removes it.
Check what you copy out of it before you share it.

## nimvault

The `nimvault:` source is deprecated, says so on each build that uses it, and is removed in 4.0.0.
A vault that can write a file or set a variable serves through `file:` or `env:` instead, for example `nimvault get licences/flexlm > ~/.config/eb-local/flexlm` with mode 600 and `file:~/.config/eb-local/flexlm`.

A `nimvault:` source runs `nimvault get ENTRY`, with `--vault` when `nimvault.vault` names the vault, and takes what it prints as the value.
nimvault has 30 seconds, since a passphrase prompt that nobody answers would otherwise hold the build until its job ends.
When it takes longer, `eb-local config --check` shows:

```text
LM_LICENSE_FILE            nimvault:licences/flexlm   FAILED: secret LM_LICENSE_FILE: nimvault get licences/flexlm took longer than 30 s (is the GPG agent waiting for a passphrase?)
```

When nimvault fails, eb-local shows its error output, never what it printed as the value.
nimvault finds its vault from `NIMVAULT_VAULT_REPO` or from the git repository of the current directory, so a build started inside another repository reads that one.
`nimvault.vault` names the vault for every build.
An entry that starts with `-` is refused, since nimvault would read it as an option:

```text
eb-local: /home/alice/.config/eb-local/config.toml:2: secret LM_LICENSE_FILE: a nimvault entry may not start with -, since nimvault would read it as an option
```

## Related

-   [Give a secret only to the builds that need it](../howto/scope-secrets.md)
-   [The configuration files](../reference/configuration.md), for `[secrets]`, `build.secrets` and `[nimvault]`
-   [Where a build puts things, and why](where-things-go.md), for the workspace and the logs
-   [The eb-local command](../reference/cli.md), for `eb-local config --check` and `eb-local doctor`
