If `clean` cannot write its list to standard output, it stops before it removes anything or makes the prefix lock.
When there is nothing to clean, `clean` forgets a recorded workstation workspace root that has no workspace only after it has written that, so a failed write changes nothing.
