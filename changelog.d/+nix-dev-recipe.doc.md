The how-to "Compile with Nix inside the dev shell" links a stack
library from `nix-shell` with `DT_RPATH`. On Nix 2.35.6 that entry
stays, including under `nix-shell --pure`, and a sandboxed
`nix-build` fails with `cannot find -lanswer`.
