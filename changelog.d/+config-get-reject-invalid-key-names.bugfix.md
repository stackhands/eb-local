`eb-local config --get` now rejects invalid `build.node_types.<NAME>` and `secrets.<NAME>` names with exit 2 and `unknown configuration key` instead of exiting 1 as unset.
