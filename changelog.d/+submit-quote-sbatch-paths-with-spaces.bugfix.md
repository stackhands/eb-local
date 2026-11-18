`eb-local submit` now double-quotes `#SBATCH --output` and `#SBATCH --chdir` directive values when the path contains spaces or quotes so `sbatch` does not split them on whitespace.
