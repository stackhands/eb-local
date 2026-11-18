`eb-local overlay materialize --check` now refuses symbolic links at `materialized-<base>` or `provenance.toml` with exit code 2 instead of reading through them.
