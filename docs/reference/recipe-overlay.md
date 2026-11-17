<!-- Generated from docs/orgmode/reference/recipe-overlay.org by docs/export.el; edit that file. -->

# Recipe overlay file

A recipe overlay is a TOML file beside (or pointed at by) your site tree.
It names the SHA-256 digest of an upstream easyconfig and lists only the parameter replacements, patch additions, dependency variants and rationale that differ from upstream.

## Top-level keys

| Key | Required | Meaning |
|---|---|---|
| `overlay_version` | no (default `1`) | Format version; only `1` is accepted today. |
| `base_easyconfig` | no | Path or name for humans; not used when materializing. |
| `base_digest` | yes | Lowercase SHA-256 hex of the upstream easyconfig bytes. Materialization refuses when the digest differs. |
| `rationale` | no | Free text copied into `provenance.toml`. |

## Edit tables

| [replace] |  | Maps parameter names to the right-hand side that should replace the first matching assignment in the easyconfig. |
|---|---|---|
| [patches] |  | Maps a patch label to a patch file path; each becomes `('label', 'file')` appended to `patches`. |
| [dependencies.add] |  | Maps a dependency name to a full tuple literal appended to `dependencies`. |
| [dependencies.replace] |  | Maps a dependency name to the tuple that replaces the first `('name', ...)` entry. |

No Python hooks or easyblocks are allowed in an overlay; only declarative edits the format above can express.

## Example

```text
overlay_version = 1
base_easyconfig = "OpenMPI-4.1.6-GCC-13.3.0.eb"
base_digest = "0123...64 hex chars..."
rationale = """
Site MPI tuning for Slurm; rebases with eb-local overlay bump and overlay plan.
"""

[replace]
preconfigopts = "'--with-pmi=slurm'"

[patches]
site = "OpenMPI-Slurm-PMI.patch"

[dependencies.add]
zlib = "('zlib', '1.2.13-GCCcore-13.3.0')"
```

## Provenance record

`eb-local overlay materialize` writes `provenance.toml` next to the materialized recipe with `base_digest`, `overlay_digest`, paths, and the rationale.
It is for auditors and automation; EasyBuild does not read it.
