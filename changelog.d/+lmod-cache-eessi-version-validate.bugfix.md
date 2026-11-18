`eb-local lmod-cache --prefix` now validates `--eessi-version` as a single directory name and rejects `.`, `..`, and path separators with exit code 2 before walking `<prefix>/versions`.
