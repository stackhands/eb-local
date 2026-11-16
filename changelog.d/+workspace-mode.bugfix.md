A build workspace is mode 0700 even when the process umask would clear those bits. mkdir was applying the umask, and a umask of 0777 left a directory this process could not enter.
