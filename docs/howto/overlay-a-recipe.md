<!-- Generated from docs/orgmode/howto/overlay-a-recipe.org by docs/export.el; edit that file. -->

# Overlay a site recipe

Use this when a site needs a small, durable difference from an upstream easyconfig and copying the file would block upstream fixes from flowing.

```{toctree}
:maxdepth: 1
```

## Pin the upstream digest

1.  Take the upstream easyconfig from your easyconfigs tree.
2.  Compute its SHA-256 (for example `sha256sum OpenMPI.eb`).
3.  Write an overlay file with `base_digest` set to that value and a `rationale` that explains the site change.

## Materialize

Preview the output paths and validate the overlay against the current easyconfig:

```shell
eb-local overlay materialize --overlay site/OpenMPI.overlay.toml --base easyconfigs/OpenMPI-4.1.6.eb --dry-run
```

The preview does not create the output directory or either output file.
Then materialize:

```shell
eb-local overlay materialize --overlay site/OpenMPI.overlay.toml --base easyconfigs/OpenMPI-4.1.6.eb
```

When the digest still matches, this writes `materialized-OpenMPI-4.1.6.eb` and `provenance.toml` beside the overlay (or under `--out-dir`).
When upstream changed, it exits `2` and tells you to refresh using eb-stack.

## Rebase after upstream moves

Run eb-stack through eb-local so this repository does not duplicate its logic:

```shell
eb-local overlay bump -- --easyconfig easyconfigs/OpenMPI-4.1.6.eb --easyconfigs /path/to/tree
eb-local overlay plan -- --source OpenMPI-4.1.6.eb --format easyconfig --out-dir /tmp/plan
```

Update `base_digest` in the overlay to match the bumped recipe, re-run `materialize`, and build the materialized file with eb-local as usual.

## Related reading

-   [Recipe overlay file](../reference/recipe-overlay.md)
-   [eb-local and eb-stack](../explanation/eb-local-and-eb-stack.md)
