`elfcheck.isHostPath` now collapses repeated leading slashes before matching `/lib`, `/lib64`, and `/usr`, so `eb-local check` catches host libraries resolved through paths such as `//usr/lib64`.
