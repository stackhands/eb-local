# Releasing

A release is a signed tag `vX.Y.Z` on a commit of `main`. The `release`
workflow runs on the tag: it builds the static binaries for x86_64 and
aarch64, tests each on its own architecture, checks the version line against
the tag, and publishes the binaries with `SHA256SUMS`, software bills of
materials and build provenance attestations.

`cog bump` does the mechanical part. `cog.toml` runs `tools/release-prepare`
before the bump commit, which builds `CHANGELOG.md` from `changelog.d/` with
towncrier and sets the version wherever a program prints it or a download
names it; the script's header lists the files.

## Steps

1. Branch from `main`: `git switch -c chore/release-X.Y.Z origin/main`.
2. Edit the prose that names the previous release, in a commit of its own:
   the paragraph of `docs/orgmode/howto/install.org` that says what the
   previous release lacks, and the list of options added since it in
   `docs/orgmode/reference/cli.org`.
3. `cog bump --minor` (or `--patch`, `--major`, `--version X.Y.Z`). It runs
   the hook, commits `chore(version): X.Y.Z` and creates the tag on that
   commit. `cog bump --minor --dry-run` prints the version only.
4. Push the branch, open the pull request, and merge it with a merge commit
   once its checks pass, so the tagged commit is on `main`.
5. Push the tag: `git push origin vX.Y.Z`. To sign a tag cog left unsigned:
   `git tag -s -f vX.Y.Z -m "eb-local X.Y.Z" vX.Y.Z^{}` before pushing.
6. Check the release: two binaries, `SHA256SUMS`, the `.cdx.json` files, and
   `gh attestation verify FILE --repo stackhands/eb-local`.

A failed workflow leaves no release. Fix the cause, delete the tag locally
and on the remote, and tag again.
