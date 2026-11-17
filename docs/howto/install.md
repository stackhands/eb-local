<!-- Generated from docs/orgmode/howto/install.org by docs/export.el; edit that file. -->

# Install eb-local

Install the `eb-local` program for your account, from a release or from source.
On a cluster whose site installs eb-local, load the site's module, or use the `eb-local` already on `PATH`, and skip this page.

These pages describe the code on the main branch.
Release 3.1.0 is older: it reads `[build.targets]` and refuses `[build.node_types]`, has no `build.secrets`, its `--explain` prints a summary of the commands a build runs rather than the script and no `sbatch` line for each node type, and its user builds pass `--umask=022` to `eb`.
A build from the main branch prints the same version, `eb-local 3.1.0`, with its own commit.
Until the next release, install from source to have them.

## Before you start

-   A Linux host on x86\_64 or aarch64.
    The release binary is linked statically against musl, so it needs no other library.
-   For a build from source, Zig 0.17.1 and git.
-   `~/.local/bin` on your `PATH`, or another directory on it in its place below.

## Install a release

1.  Download the binary for this host's architecture and the release's checksums, and check the binary:

    ```bash
    v=3.1.0; f=eb-local-$v-$(uname -m)-linux-musl
    mkdir -p ~/.local/bin && cd ~/.local/bin
    curl -fLO "https://github.com/stackhands/eb-local/releases/download/v$v/$f"
    curl -fL "https://github.com/stackhands/eb-local/releases/download/v$v/SHA256SUMS" | sha256sum -c --ignore-missing
    ```

    ```text
    eb-local-3.1.0-x86_64-linux-musl: OK
    ```

2.  With the GitHub CLI, you can also check the build provenance attestation of the binary, and that of its CycloneDX software bill of materials (SBOM), `$f.cdx.json` in the release:

    ```bash
    gh attestation verify "$f" --repo stackhands/eb-local
    gh attestation verify "$f" --repo stackhands/eb-local --predicate-type https://cyclonedx.org/bom
    ```

    Each exits 0 when the attestation matches the file.

3.  Name the binary `eb-local`:

    ```bash
    mv "$f" eb-local && chmod 755 eb-local
    ```

## Install from source

Build the main branch with Zig 0.17.1, with the commit in the version line, and install the binary:

```bash
git clone https://github.com/stackhands/eb-local.git
cd eb-local
zig build --release=safe -Dcommit=$(git rev-parse --short=7 HEAD)
install -D -m 755 zig-out/bin/eb-local ~/.local/bin/eb-local
```

The first build downloads the one dependency that `build.zig.zon` names.

## Check that it worked

```bash
command -v eb-local
eb-local --version
```

```text
/home/alice/.local/bin/eb-local
eb-local 3.1.0 (x86_64-linux-musl, safe, zig 0.17.1, 8755a6a)
```

The last part of the version line is the commit: `8755a6a` is release 3.1.0, and a build from source shows the commit it was built from.
`eb-local env` and `eb-local dev` work from here.
A build with EasyBuild also needs a site file beside the program, which `eb-local site install` writes.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local-3.1.0-x86_64-linux-musl: FAILED` and `sha256sum: WARNING: 1 computed checksum did NOT match` | The file is not the one the checksums name, as after a broken download. | Download it again, and check it again. |
| `curl: (22) The requested URL returned error: 404` | The release has no binary of that name: the architecture is neither x86\_64 nor aarch64, or `v` names no release. | Install from source, or set `v` to a release. |
| `eb-local: FILE:1: unknown key build.node_types` | Release 3.1.0 reads a site file written for the main branch. | Install from source, or name the table `[build.targets]` for 3.1.0. |
| The shell does not find `eb-local` | `~/.local/bin` is not on `PATH`. | Add it to `PATH` in your shell's startup file. |

## Related

-   [The eb-local command](../reference/cli.md)
-   [The configuration files](../reference/configuration.md)
