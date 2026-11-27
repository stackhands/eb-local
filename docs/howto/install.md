<!-- Generated from docs/orgmode/howto/install.org by docs/export.el; edit that file. -->

# Install eb-local

Install the `eb-local` program for your account, from a release or from source.
On a cluster whose site installs eb-local, load the site's module, or use the `eb-local` already on `PATH`, and skip this page.

These pages describe release 3.6.0.
Release 3.5.0 is older: it has no `--variant`, so it builds no `-perf` or `-debug` module; no `--cpu-target` and `--mask`, so it builds only for the CPU of the build host; no `audit-isa` command; and no `doctor --profiling`. The [changelog](https://github.com/stackhands/eb-local/blob/main/CHANGELOG.md) lists what each earlier release lacks.
A build from the main branch prints the version of the last release, with its own commit.
[Find what is wrong before a build](find-what-is-wrong.md) copies `eb-local-readiness` from a pinned `main` commit when you use the release binary.

## Before you start

-   A Linux host on x86\_64 or aarch64.
    The release binary is linked statically against musl, so it needs no other library.
-   For a build from source, Zig 0.17.1 and git.
-   `~/.local/bin` on your `PATH`, or another directory on it in its place below.

## Install a release

1.  Download the binary for this host's architecture and the release's checksums, and check the binary:

    ```bash
    v=3.5.0; f=eb-local-$v-$(uname -m)-linux-musl
    mkdir -p ~/.local/bin && cd ~/.local/bin
    curl -fLO "https://github.com/stackhands/eb-local/releases/download/v$v/$f"
    curl -fL "https://github.com/stackhands/eb-local/releases/download/v$v/SHA256SUMS" | sha256sum -c --ignore-missing
    ```

    ```text
    eb-local-3.5.0-x86_64-linux-musl: OK
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
eb-local 3.5.0 (x86_64-linux-musl, safe, zig 0.17.1, 0123abc)
```

The last part of the version line is the commit the binary was built from: the release commit for a release binary, and your checkout's for a build from source.
`./eb-local --version` in a source checkout resolves the shim's real directory, tries `zig-out/bin/eb-local` there, then searches each `PATH` directory for another `eb-local`; this page checks the installed binary on your `PATH`.
`eb-local env` and `eb-local dev` work from here.
`eval "$(eb-local env --strict)"` stops with exit 2 until the EESSI init file exists, as [Load EESSI before a build](load-eessi.md) describes.
Site operators refresh Lmod's cache with `eb-local lmod-cache`, as [Refresh the module cache](refresh-the-module-cache.md) describes.
A build with EasyBuild also needs a site file, which [Write the site file for a cluster](write-a-site-file.md) installs.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local-3.5.0-x86_64-linux-musl: FAILED` and `sha256sum: WARNING: 1 computed checksum did NOT match` | The file is not the one the checksums name, as after a broken download. | Download it again, and check it again. |
| `curl: (22) The requested URL returned error: 404` | The release has no binary of that name: the architecture is neither x86\_64 nor aarch64, or `v` names no release. | Install from source, or set `v` to a release. |
| `eb-local: FILE:1: unknown key build.node_types` | Release 3.1.0 reads a site file written for 3.2.0. | Install release 3.2.0, or name the table `[build.targets]` for 3.1.0. |
| The shell does not find `eb-local` | `~/.local/bin` is not on `PATH`. | Add it to `PATH` in your shell's startup file. |

## Related

-   [Write the site file for a cluster](write-a-site-file.md)
-   [The eb-local command](../reference/cli.md)
-   [The configuration files](../reference/configuration.md)
