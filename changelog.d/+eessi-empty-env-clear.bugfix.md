A profile can clear a site `EESSI_*` variable by setting it to empty. Exporting it with `config --env` selects no profile. The next load now keeps the clear and no longer restores the site value.
