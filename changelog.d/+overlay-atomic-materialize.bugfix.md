`eb-local overlay materialize` now writes both outputs via `atomicWrite` and rolls back the materialized easyconfig and any newly created output directory if writing `provenance.toml` fails.
