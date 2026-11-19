`legacyToToml` now rejects a leading UTF-8 BOM and validates every line (including comments) for NUL and non-UTF-8 bytes with its line number before stripping comments.
