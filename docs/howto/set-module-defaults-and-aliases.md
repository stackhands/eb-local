<!-- Generated from docs/orgmode/howto/set-module-defaults-and-aliases.org by docs/export.el; edit that file. -->

# Set module defaults, aliases and hidden versions

Use `modulerc` when an operator has already chosen which module versions should be defaults, aliases or hidden.

Name the module tree and every directive explicitly:

```bash
eb-local modulerc \
  --module-tree /opt/modules/all \
  --default Example/2.0 \
  --alias Example/latest=Example/2.0 \
  --hide Example/1.0
```

The command writes these lines to `/opt/modules/all/.modulerc.lua`:

```lua
module_version("Example/2.0", "default")
module_alias("Example/latest", "Example/2.0")
hide_version("Example/1.0")
```

Preview the complete resulting file without changing it:

```bash
eb-local modulerc \
  --module-tree /opt/modules/all \
  --default Example/2.0 \
  --dry-run
```

Existing lines stay in the file.
Repeating the same command leaves the bytes unchanged.
The command never scans installed versions or chooses a default.
