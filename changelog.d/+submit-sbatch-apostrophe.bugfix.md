The scheduler read an apostrophe in a `#SBATCH` `--output` or
`--chdir` path as an opening quote, stopped on the unmatched quote
and never submitted the job. `eb-local submit` now double-quotes
such a path.
