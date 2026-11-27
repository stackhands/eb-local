Lmod prints a modulerc alias from `module --terse avail` as `name(@target)`.
The cache check treated that token as a module name and refused the inventory.
It now keeps the alias name.
