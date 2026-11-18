`toml.parse` now rejects unescaped `0x7f` (DEL) bytes inside basic and literal strings as control characters, matching TOML 1.0 and `sites.validValue`.
