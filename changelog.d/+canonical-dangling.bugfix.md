A symbolic link whose target does not exist yet is resolved the way `readlink -m` does, so a dangling link from the installation prefix onto shared scratch is refused before a workspace is made.
