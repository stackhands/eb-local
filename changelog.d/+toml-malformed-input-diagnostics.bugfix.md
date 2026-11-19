`toml.parse` now rejects a leading UTF-8 BOM cleanly, reports the exact line number for NUL and non-UTF-8 bytes, and reports unclosed single-line strings on CRLF endings.
