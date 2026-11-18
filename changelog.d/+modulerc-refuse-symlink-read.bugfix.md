`eb-local modulerc --check` and `--dry-run` now refuse a symbolic-link `.modulerc.lua` with exit code 2 instead of reading through it, matching the write path's symlink refusal.
