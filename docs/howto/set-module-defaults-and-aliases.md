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

## Check for drift

Use `--check` in site automation to test whether applying the requested directives would change the file.
Set `MODULE_TREE` to the absolute module tree directory first.

```bash
eb-local modulerc \
  --module-tree "$MODULE_TREE" \
  --default Example/2.0 \
  --check
```

When the file needs the directive, the command writes nothing, prints:

```text
would update MODULE_TREE/.modulerc.lua
```

and exits 1.
After the directive is present, it prints `up to date MODULE_TREE/.modulerc.lua` and exits 0.

Existing lines stay in the file.
Repeating the same command leaves the bytes unchanged.
The command never scans installed versions or chooses a default.
