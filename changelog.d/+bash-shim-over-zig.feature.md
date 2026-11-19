The repository's `eb-local` POSIX shell shim delegates every command
to the Zig program, avoids delegating to shim copies and preserves an
adjacent `eb-local.conf`. For Bash users, the default prefix moves from
`~/.local/eessi` to `~/eessi` while retaining an existing legacy
install. User installs change from umask 022 to 077, so other users can
no longer read them. An untrusted adjacent config is rejected instead
of skipped, and child signals are re-raised rather than translated to
status 128 plus the signal number.
