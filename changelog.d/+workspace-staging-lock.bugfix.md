Stage and lock `.eb-local.lock` before publishing `eb-local.XXXXXXXX` build workspaces so `clean --workspaces` cannot delete a build workspace waiting on `.eb-local/.lock`.
