`eb-local` ignores `SIGXFSZ` while replacing log files during secret redaction so `RLIMIT_FSIZE` failures report `EFBIG` and sibling logs continue redacting.
