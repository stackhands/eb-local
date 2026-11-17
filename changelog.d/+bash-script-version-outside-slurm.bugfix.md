The frozen 1.x Bash script now handles `--version` before any Slurm checks, so `eb-local --version` and `eb-local --help` both exit successfully outside a job allocation.
