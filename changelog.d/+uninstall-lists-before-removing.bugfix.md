If `uninstall` cannot write its list to standard output, it stops before it removes anything or makes the prefix lock.
If a module file or link for what it listed appears while it waits for the prefix lock, `uninstall` removes nothing, so it leaves no dangling link behind.
