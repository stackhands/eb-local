`eb-local check` now expands `$ORIGIN` and `${ORIGIN}` in `DT_NEEDED` entries that contain `/`, so plain and `--recursive` checks resolve and audit those shared libraries.
