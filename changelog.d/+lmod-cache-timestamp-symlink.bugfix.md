`eb-local lmod-cache` now opens the timestamp file with `O_NOFOLLOW`, refusing symbolic links without clobbering their targets and rolling back any newly written cache file.
