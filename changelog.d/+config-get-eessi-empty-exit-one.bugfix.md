`eb-local config --get eessi.<NAME>` now exits 1 with empty stdout when the configured `[eessi]` entry is empty, matching all other scalar keys and the documented `--get` contract.
