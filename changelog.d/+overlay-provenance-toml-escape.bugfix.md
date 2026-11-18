`eb-local overlay materialize` now escapes backslashes, control characters, and consecutive or trailing quotes inside `provenance.toml` `rationale` and string fields, ensuring valid TOML output.
