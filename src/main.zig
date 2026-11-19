//! eb-local: install and build software on top of EESSI into a directory you
//! own. Configuration is layered TOML (see config.zig); secrets come from the
//! environment, owner-only files or nimvault (see secrets.zig).
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const cli = common.cli;
/// The part of TOML the configuration files are written in.
pub const toml = @import("toml.zig");
/// The settings in force, and where each came from.
pub const config = @import("config.zig");
/// Where a secret's value comes from, and its removal from the logs.
pub const secrets = @import("secrets.zig");
/// The site file templates `eb-local site` renders.
pub const sites = @import("sites.zig");
/// Where a build may write: the allocation's node-local mount and the prefix.
pub const storage = @import("storage.zig");
/// The RPATH wrappers `dev` writes for compilers without a build environment.
pub const rpath = @import("rpath.zig");
/// `eb-local check`: what a program needs, and where it finds it.
pub const elfcheck = @import("elfcheck.zig");
/// `eb-local eb`: EasyBuild through EESSI-extend, without a site file.
pub const extend = @import("extend.zig");
/// `eb-local lmod-cache`: the spider cache Lmod trusts.
pub const lmodcache = @import("lmodcache.zig");
/// `eb-local modulerc`: operator-selected Lmod defaults, aliases and hides.
pub const modulerc = @import("modulerc.zig");
/// Foreign prefixes and container binds `doctor` reports.
pub const foreign = @import("foreign.zig");
/// CernVM-FS checks for `doctor --cvmfs`. A build does not call them.
pub const cvmfs = @import("cvmfs.zig");
/// MPI transport checks for `doctor --mpi`. A build does not call them.
pub const mpi = @import("mpi.zig");
/// `eb-local overlay`: declarative site overlays for upstream easyconfigs.
pub const recipe_overlay = @import("recipe_overlay.zig");
/// `--json` for scriptable commands.
const jsonout = @import("jsonout.zig");
const Allocator = std.mem.Allocator;

const tool = "eb-local";
/// The version `eb-local --version` prints, and the release it is.
pub const version = "3.1.0";

const usage_text =
    \\eb-local: install and build software on top of EESSI 2026.06, into a
    \\directory you own.
    \\
    \\  eb-local <easyconfig> [eb options]   build and install with EasyBuild
    \\  eb-local --explain <easyconfig> [eb options]
    \\                                       the commands that build runs, as shell lines,
    \\                                       its checks as comments; creates and runs nothing
    \\  eb-local eb [--] [eb options]        load EESSI-extend and run eb; no site file, no Slurm job.
    \\                                       At most one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL,
    \\                                       EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL may be set, and a
    \\                                       present empty value counts as set; with none set, the
    \\                                       module uses $HOME/eessi and nothing is exported.
    \\                                       eb runs only if the module's install path is in the
    \\                                       tree that variable selects
    \\  eb-local --explain eb [--] [eb options]
    \\                                       the script eb runs, with its arguments; runs nothing
    \\  eb-local env [--strict] [--json]       lines that make your installed modules visible;
    \\                                       --strict exits when the EESSI init file is missing
    \\                                       (also when EB_LOCAL_ENV_STRICT=1)
    \\  eb-local dev [--strict] [--json] [--buildenv MODULE] [MODULE...]
    \\                                       the same, plus MODULEs and a build environment,
    \\                                       so gcc, make, cmake and meson just work;
    \\                                       --strict exits when the EESSI init file is missing
    \\                                       (also when EB_LOCAL_ENV_STRICT=1);
    \\                                       --buildenv names the build environment to load;
    \\                                       --json prints the change as JSON, for env too
    \\  eb-local rpath-wrappers [--for FAMILY | --unwrapped]
    \\                                       lines that put RPATH wrappers for the compilers
    \\                                       on PATH first; dev uses them when no build
    \\                                       environment exists for the loaded compilers.
    \\                                       --unwrapped: only clang, clang++, flang,
    \\                                       flang-new and ld.lld, where no wrapper comes
    \\                                       first; dev adds them after a build environment
    \\  eb-local check [--recursive] [--quiet] [--json] FILE...
    \\                                       whether a program or library built here runs here:
    \\                                       its architecture, loader, run paths and libraries;
    \\                                       --recursive audits resolved DT_NEEDED libraries too
    \\  eb-local check (--module NAME/VERSION... | --dev | --prefix DIR) [--recursive] [--quiet] [--json]
    \\                                       the same for every ELF file in those installations,
    \\                                       the dev tree, or DIR; a file that is not ELF is skipped.
    \\                                       --quiet prints a file only when it has a problem
    \\  eb-local submit [--on NAME,...] [--print] <easyconfig> [eb options]
    \\                                       one batch job per node type the site file lists
    \\                                       in build.node_types, each building the recipe for
    \\                                       its CPU target; --print shows the jobs instead.
    \\                                       Deprecated, and removed in 4.0.0: --explain
    \\                                       prints an sbatch line for each node type
    \\  eb-local list [--json | --missing] [NAME[/VERSION]...]
    \\                                       what you installed, for which CPU targets, and
    \\                                       what this node's target lacks; --json prints one
    \\                                       line of JSON with schema_version 1; --missing
    \\                                       lists only modules missing on this node's target
    \\  eb-local doctor [--json] [--strict] [--workspace PATH] [--cvmfs] [--cvmfs-parallel N] [--mpi]
    \\                                       what in this shell, node or configuration would
    \\                                       stop a build or a module load; changes nothing;
    \\                                       --json prints one line of JSON with schema_version 1.
    \\                                       --strict exits 1 on warn lines as well as FAIL.
    \\                                       --workspace probes PATH without starting a build.
    \\                                       --cvmfs checks the CernVM-FS client.
    \\                                       --cvmfs-parallel N (1 to 8) reads repository
    \\                                       metadata from N tasks inside an allocation.
    \\                                       --mpi reports libfabric and UCX, and inside an
    \\                                       allocation runs a two-rank hello per approved transport
    \\  eb-local lmod-cache --modulepath DIR[:DIR] --cache-dir DIR
    \\                      --timestamp FILE [--spider CMD] [--verify]
    \\                                       write Lmod's spiderT.lua for those module
    \\                                       directories, and a timestamp one second
    \\                                       older, so Lmod trusts the cache. A spider
    \\                                       that fails leaves both files unchanged.
    \\                                       --spider names the spider program;
    \\                                       default: spider. --verify compares
    \\                                       cached and uncached module inventories.
    \\                                       Does not read the site file
    \\  eb-local lmod-cache --prefix DIR [--eessi-version VER] [--update-cmd CMD]
    \\                      [--dry-run]
    \\                                       for every CPU target under DIR, refresh
    \\                                       .lmod/cache with Lmod's cache updater
    \\                                       (like EESSI's update_lmod_caches.sh).
    \\                                       --dry-run lists targets; existing
    \\                                       --modulepath mode is unchanged
    \\  eb-local modulerc --module-tree DIR [--default MODULE]...
    \\                     [--alias NAME=MODULE]... [--hide MODULE]... [--dry-run | --check] [--json]
    \\                                       write DIR/.modulerc.lua with the
    \\                                       defaults, aliases and hidden versions named;
    \\                                       preserve other lines. --dry-run prints the file;
    \\                                       --check reports drift and writes nothing;
    \\                                       --json prints one line of JSON with schema_version 1
    \\  eb-local clean [--logs-older-than DAYS] [--no-logs] [--sources] [--workspaces]
    \\                 [--dry-run] [--delete] [--json]
    \\                                       remove what eb-local left behind; --no-logs
    \\                                       leaves the logs; --json prints one line of JSON
    \\  eb-local config [--check | --env | --get KEY] [--json]
    \\                                       the settings in force and where each came from;
    \\                                       --check also reads every secret (values not shown);
    \\                                       --env prints them as EB_LOCAL_* lines for export;
    \\                                       --get prints one resolved key's value (secret sources only);
    \\                                       --json is for the default output or --check, not --env or --get
    \\  eb-local profiles [--json]           the profiles the configuration defines; --json
    \\                                       prints one line of JSON with schema_version 1
    \\  eb-local uninstall NAME/VERSION... [--target TARGET] [--dry-run] [--delete]
    \\                                       [--usage-log FILE]
    \\                                       remove an installation and its module file, for
    \\                                       every CPU target (or only TARGET), to the trash with
    \\                                       rtrash. --usage-log asks eb-keep-logs whether the
    \\                                       prefix is in FILE, and removes nothing when that exits 2
    \\  eb-local restore NAME/VERSION... [--dry-run]
    \\                                       bring them back from the trash, read-only again
    \\  eb-local site [list | show NAME | install NAME | check FILE] [--set KEY=VALUE]... [--to FILE] [--force]
    \\                                       a site file from a template built in, or from a
    \\                                       template file (a NAME with a slash); install
    \\                                       writes config.toml beside this program, mode 644;
    \\                                       site list takes --json for machine-readable output
    \\  eb-local overlay materialize --overlay FILE --base PATH [--out-dir DIR] [--dry-run | --check]
    \\                                       apply a digest-pinned overlay; writes a materialized
    \\                                       easyconfig and provenance.toml, or refuses when the
    \\                                       base digest changed; --dry-run validates and lists
    \\                                       the outputs without writing them; --check reports drift
    \\                                       and writes nothing
    \\  eb-local overlay bump [--eb-stack PATH] [--] [eb-stack package bump options...]
    \\  eb-local overlay plan [--eb-stack PATH] [--] [eb-stack package plan options...]
    \\                                       run eb-stack package bump or plan by subprocess only
    \\  eb-local help | --version
    \\
    \\Every command but eb takes --profile NAME, --project DIR (a shared project
    \\directory instead of $HOME/eessi) and --config FILE. Use env and dev with eval:
    \\
    \\  eval "$(eb-local env)"
    \\  eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
    \\
    \\Configuration: the site file (the first of config.toml beside this program,
    \\/etc/eb-local/config.toml, eb-local.conf beside this program and
    \\/etc/eb-local.conf), then ~/.config/eb-local/config.toml,
    \\then EB_LOCAL_* variables (EB_LOCAL_SECRET_NAME=SOURCE for a secret),
    \\then options. Builds use the allocation's own
    \\node-local mount; a successful build removes its workspace unless
    \\EB_LOCAL_KEEP_WORK=1. Secrets reach eb's environment only, and logs
    \\written during a build are cleaned of them. A build gets every secret,
    \\unless build.secrets or EB_LOCAL_BUILD_SECRETS names the ones it gets.
    \\
    \\--config FILE, or EB_LOCAL_CONFIG=FILE without it, is read in place of the
    \\site file when root or this program's owner owns it, otherwise in place of
    \\your ~/.config/eb-local/config.toml when you own it; the other file is
    \\still read, and only a site file may set the storage settings.
    \\
;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn oom() noreturn {
    die("out of memory", .{});
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    cli.out(fmt ++ "\n", args);
}

const Ctx = struct {
    a: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    cwd: []const u8,
};

// ---- shell output ---------------------------------------------------------

fn q(a: Allocator, s: []const u8) []const u8 {
    return common.pytext.shellQuote(a, s) catch oom();
}

fn str(a: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, f, args) catch oom();
}

const install_vars = [_][]const u8{
    "EESSI_CVMFS_INSTALL",               "EESSI_SITE_INSTALL",            "EESSI_USER_INSTALL",
    "EESSI_PROJECT_INSTALL",             "EESSI_SITE_SOFTWARE_PREFIX",    "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
    "EESSI_ACCELERATOR_TARGET_OVERRIDE", "EESSI_OVERRIDE_GPU_CHECK",      "EASYBUILD_INSTALLPATH",
    "EASYBUILD_INSTALLPATH_SOFTWARE",    "EASYBUILD_INSTALLPATH_MODULES", "EASYBUILD_PREFIX",
};

/// What, left in a shell, sends a later load of EESSI-extend, or eb after
/// it, somewhere else: EESSI-extend sets the other install variables itself.
const leftover_vars = [_][]const u8{
    "EESSI_USER_INSTALL",             "EESSI_PROJECT_INSTALL",         "EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL",
    "EASYBUILD_INSTALLPATH_SOFTWARE", "EASYBUILD_INSTALLPATH_MODULES",
};

const Place = struct {
    prefix: []const u8,
    project: bool,
};

/// What `eb-local env` set, if NAME=VALUE is that: its install variable,
/// naming P's prefix, or, when the extension env loads for a prefix that
/// exists is loaded, the install path it chose in the prefix's versions
/// tree, or the EasyBuild prefix it sets beside that path.
fn ownInstallVar(c: Ctx, s: config.Settings, p: Place, name: []const u8, value: []const u8) ?[]const u8 {
    const mine = if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL";
    if (std.mem.eql(u8, name, mine)) {
        return if (std.mem.eql(u8, storage.canonical(c.a, value, c.cwd) catch oom(), p.prefix)) "names your prefix, as eb-local env sets it" else null;
    }
    const is_path = std.mem.eql(u8, name, "EASYBUILD_INSTALLPATH");
    if (!is_path and !std.mem.eql(u8, name, "EASYBUILD_PREFIX")) return null;
    if (!moduleLoaded(c, s.extend_module.value)) return null;
    const installpath = nonEmpty(c.env.get("EASYBUILD_INSTALLPATH")) orelse return null;
    const versions = std.fs.path.join(c.a, &.{ p.prefix, "versions" }) catch oom();
    const path = storage.canonical(c.a, installpath, c.cwd) catch oom();
    if (!storage.under(path, versions) or std.mem.eql(u8, path, versions)) return null;
    return if (is_path) "is in your prefix, as EESSI-extend sets it when eb-local env loads it" else "is EESSI-extend's own, set when eb-local env loads it";
}

/// Whether Lmod lists MODULE, a name or a name and version, as loaded.
fn moduleLoaded(c: Ctx, module: []const u8) bool {
    var it = std.mem.splitScalar(u8, c.env.get("LOADEDMODULES") orelse "", ':');
    while (it.next()) |m| {
        if (std.mem.eql(u8, m, module)) return true;
        if (std.mem.startsWith(u8, m, module) and m.len > module.len and m[module.len] == '/') return true;
    }
    return false;
}

/// Before `env` or `dev` lines run, optionally refuse when CVMFS has not mounted EESSI.
const env_strict_prelude =
    \\repo=${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}
    \\ver=${EESSI_VERSION:-2026.06}
    \\init=${repo}/versions/${ver}/init/lmod/bash
    \\if [[ ! -e $init ]]; then
    \\  echo "eb-local: missing ${init}; mount EESSI with CVMFS, use the EESSI container, or set EESSI_CVMFS_REPO and EESSI_VERSION." >&2
    \\  exit 2
    \\elif [[ ! -f $init || ! -r $init ]]; then
    \\  echo "eb-local: cannot read ${init}; mount EESSI with CVMFS, use the EESSI container, or set EESSI_CVMFS_REPO and EESSI_VERSION." >&2
    \\  exit 2
    \\fi
    \\
;

fn environmentLines(c: Ctx, s: config.Settings, p: Place, strict: bool) []const u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    if (strict) add(a, &out, env_strict_prelude);
    add(a, &out, lmod_init);
    add(a, &out, str(a, "module unload {s} >/dev/null 2>&1 || true\n", .{q(a, s.extend_module.value)}));
    add(a, &out,
        \\unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL
        \\unset EESSI_SITE_SOFTWARE_PREFIX
        \\unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK
        \\unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX
        \\
    );
    add(a, &out, str(a, "export {s}={s}\n", .{ if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", q(a, p.prefix) }));
    // [eessi] settings before the stack loads: the EESSI module and its
    // hooks read them then.
    for (s.eessi.items) |v| add(a, &out, str(a, "export {s}={s}\n", .{ v.name, q(a, v.value) }));
    // Lmod finds every module of a load before it loads any, and the
    // extension is on MODULEPATH only once the stack is loaded, so each has
    // a load of its own. EESSI-extend refuses an install directory that does
    // not exist; before the first install there are no modules of yours to
    // show, so the stack is loaded alone.
    add(a, &out, str(a, "module load {s}\n", .{q(a, s.stack_module.value)}));
    // Tasks run with the CPU target eessi-arch-guard selects, which can be
    // below the one EESSI detects; where the guard is installed, it moves the
    // stack there before EESSI-extend reads its install path.
    add(a, &out, "if command -v eessi-arch-guard >/dev/null 2>&1; then eval \"$(eessi-arch-guard --shell)\"; fi\n");
    const exists_dir = if (fsx.statAt(fsx.cwd, p.prefix, true)) |st| st.isDir() else |_| false;
    if (exists_dir) add(a, &out, str(a, "module load {s}\n", .{q(a, s.extend_module.value)}));
    // build.site_toolchains under the version the stack set, as a build
    // exports it, so eb run by hand after env or dev accepts them too.
    if (s.site_toolchains.value.len > 0) {
        const json = config.toolchainsJson(a, s.site_toolchains.value) catch oom();
        add(a, &out, str(a,
            \\if [ -n "${{EESSI_VERSION-}}" ]; then
            \\    export "EESSI_SITE_TOP_LEVEL_TOOLCHAINS_$(printf %s "$EESSI_VERSION" | tr . _)="{s}
            \\fi
            \\
        , .{q(a, json)}));
    }
    return out.items;
}

fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn isTerminal(fd: sys.fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) == .SUCCESS;
}

fn evalHint(words: []const u8) void {
    if (isTerminal(1)) {
        warn("these lines change nothing until the shell runs them:", .{});
        cli.err("  eval \"$(eb-local {s})\"\n", .{words});
    }
}

/// The command that reproduces this environment: the config file, profile,
/// project and (for dev) buildenv that selected it, shell-quoted, options
/// before the command. A hint that drops them tells the reader to eval a
/// different environment.
fn replay(a: Allocator, command: []const u8, s: config.Settings, g: Global, canonical_prefix: []const u8, extra: []const []const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (g.config_file) |p| parts.appendSlice(a, &.{ "--config", q(a, p) }) catch oom();
    if (s.profile) |p| parts.appendSlice(a, &.{ "--profile", q(a, p) }) catch oom();
    if (s.project.value != null) parts.appendSlice(a, &.{ "--project", q(a, canonical_prefix) }) catch oom();
    parts.append(a, command) catch oom();
    if (std.mem.eql(u8, command, "dev")) {
        if (g.buildenv) |p| parts.appendSlice(a, &.{ "--buildenv", q(a, p) }) catch oom();
        for (extra) |m| parts.append(a, q(a, m)) catch oom();
    }
    return std.mem.join(a, " ", parts.items) catch oom();
}

// ---- configuration files --------------------------------------------------

fn selfExe(buf: *[sys.path_max]u8) ?[]const u8 {
    const n = linux.readlinkat(linux.AT.FDCWD, "/proc/self/exe", buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0 or n >= buf.len) return null;
    return buf[0..n];
}

fn selfDir(a: Allocator) []const u8 {
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse return "/";
    return a.dupe(u8, std.fs.path.dirname(exe) orelse "/") catch oom();
}

/// Set in main from EB_LOCAL_TEST_SELF_OWNER, only in the test artifact,
/// so a test can make this program look installed by another account.
var test_self_owner: ?linux.uid_t = null;

fn selfOwner() linux.uid_t {
    if (comptime build_options.test_ops) {
        if (test_self_owner) |u| return u;
    }
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse return 0;
    const st = fsx.statAt(fsx.cwd, exe, true) catch return 0;
    return st.uid;
}

const Trust = enum { site, user };

/// Read a configuration file that may steer builds: a regular file, not a
/// symbolic link, not writable by group or others, owned by root or this
/// program's owner (a site file) or by the caller (a user file). A site
/// file the caller owns is refused unless the caller owns the program too:
/// only the site file sets the storage settings and build.site_toolchains.
/// A file that fails is an error, never skipped.
fn readTrusted(c: Ctx, path: []const u8, kind: Trust) []const u8 {
    const opened = openConfig(path);
    defer sys.close(opened.fd);
    const uid = opened.stat.uid;
    switch (kind) {
        .site => {
            const owner = selfOwner();
            if (uid != 0 and uid != owner)
                die("{s} is owned by uid {d} and is not used: a site file belongs to root or to this program's owner (uid {d})", .{ path, uid, owner });
        },
        .user => if (uid != linux.getuid())
            die("{s} is owned by uid {d} and is not used: your configuration file belongs to you (uid {d})", .{ path, uid, linux.getuid() }),
    }
    return fsx.readAll(c.a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ path, @errorName(e) });
}

const Opened = struct { fd: sys.fd_t, stat: fsx.Stat };

/// A configuration file: a regular file, not a symbolic link, not writable
/// by group or others. A file that fails is an error, never skipped.
fn openConfig(path: []const u8) Opened {
    const lst = fsx.statAt(fsx.cwd, path, false) catch |e| die("cannot open {s} ({s})", .{ path, storage.describeError(e) });
    if (lst.isLink()) die("{s} is a symbolic link; a configuration file must be a regular file", .{path});
    const opened = fsx.openRegular(fsx.cwd, path, false) catch |e| die("cannot open {s} ({s})", .{ path, storage.describeError(e) });
    if (opened.stat.mode & 0o022 != 0) die("{s} is writable by group or others and is not used; chmod go-w it", .{path});
    return .{ .fd = opened.fd, .stat = opened.stat };
}

/// The layer a file named with --config or EB_LOCAL_CONFIG belongs to: a
/// site file when root or this program's owner owns it, a user file when
/// the caller does. Only a site file may set [storage], so a user cannot
/// point builds at a shared file system by naming a file of their own.
fn explicitTrust(path: []const u8) Trust {
    const opened = openConfig(path);
    defer sys.close(opened.fd);
    const uid = opened.stat.uid;
    if (uid == 0 or uid == selfOwner()) return .site;
    if (uid == linux.getuid()) return .user;
    die("{s} is owned by uid {d} and is not used", .{ path, uid });
}

fn exists(path: []const u8) bool {
    _ = fsx.statAt(fsx.cwd, path, false) catch return false;
    return true;
}

fn sourceFrom(c: Ctx, path: []const u8, kind: Trust) config.Source {
    const raw = readTrusted(c, path, kind);
    const layer: config.Layer = if (kind == .site) .site else .user;
    if (std.mem.endsWith(u8, path, ".toml")) return .{ .path = path, .text = raw, .layer = layer };
    var d: config.Diagnostic = .{};
    const text = config.legacyToToml(c.a, raw, &d) catch |e| switch (e) {
        error.Invalid => die("{s}: {s}", .{ path, d.message }),
        error.OutOfMemory => oom(),
    };
    return .{ .path = path, .text = text, .layer = layer };
}

const Global = struct {
    profile: ?[]const u8 = null,
    project: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    buildenv: ?[]const u8 = null,
    /// Print what a build would run, as shell commands, and run nothing.
    explain: bool = false,
    /// `env --strict`: refuse to print load lines when the EESSI init path is absent.
    env_strict: bool = false,
    /// One line of JSON on stdout instead of the human report.
    json_out: bool = false,
    /// `dev --envrc`: write the dev line to `.envrc` here, for direnv.
    envrc: bool = false,
};

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const x = v orelse return null;
    return if (x.len > 0) x else null;
}

/// The configuration files in force, site first.
fn configSources(c: Ctx, g: Global) []const config.Source {
    var sources: std.ArrayList(config.Source) = .empty;
    const explicit = g.config_file orelse nonEmpty(c.env.get("EB_LOCAL_CONFIG"));
    const explicit_trust: ?Trust = if (explicit) |path| blk: {
        if (!exists(path)) die("the configuration file {s} does not exist", .{path});
        break :blk explicitTrust(path);
    } else null;
    // The site file: a named one the site owns replaces the installed one.
    if (explicit_trust == .site) {
        sources.append(c.a, sourceFrom(c, explicit.?, .site)) catch oom();
    } else {
        const dir = selfDir(c.a);
        const candidates = [_][]const u8{
            std.fs.path.join(c.a, &.{ dir, "config.toml" }) catch oom(),
            "/etc/eb-local/config.toml",
            std.fs.path.join(c.a, &.{ dir, "eb-local.conf" }) catch oom(),
            "/etc/eb-local.conf",
        };
        for (candidates) |p| if (exists(p)) {
            sources.append(c.a, sourceFrom(c, p, .site)) catch oom();
            break;
        };
    }
    // The user file: a named one the caller owns replaces the usual one.
    if (explicit_trust == .user) {
        sources.append(c.a, sourceFrom(c, explicit.?, .user)) catch oom();
    } else {
        const user_file: ?[]const u8 = if (nonEmpty(c.env.get("XDG_CONFIG_HOME"))) |x|
            std.fs.path.join(c.a, &.{ x, "eb-local", "config.toml" }) catch oom()
        else if (nonEmpty(c.env.get("HOME"))) |h|
            std.fs.path.join(c.a, &.{ h, ".config", "eb-local", "config.toml" }) catch oom()
        else
            null;
        if (user_file) |p| if (exists(p)) sources.append(c.a, sourceFrom(c, p, .user)) catch oom();
    }
    return sources.items;
}

fn loadSettings(c: Ctx, g: Global) config.Settings {
    var d: config.Diagnostic = .{};
    return config.load(c.a, configSources(c, g), c.env, .{ .profile = g.profile, .project = g.project, .buildenv = g.buildenv }, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
}

/// The installation directory, absolute even before it exists. A project
/// directory that cannot be used stops eb-local.
fn place(c: Ctx, s: config.Settings) Place {
    if (s.project.value) |p| if (!projectUsable(c, p)) std.process.exit(2);
    return locate(c, s);
}

/// Whether the project directory p can be used; what is wrong with it goes
/// to stderr.
fn projectUsable(c: Ctx, p: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, p, true) catch {
        warn("project directory {s} does not exist.", .{p});
        cli.err("  The project owner creates it once, with the project group and g+s:\n", .{});
        const qp = q(c.a, p);
        cli.err("  mkdir -p {s} && chgrp <group> {s} && chmod 2770 {s}\n", .{ qp, qp, qp });
        return false;
    };
    if (!st.isDir()) {
        warn("project directory {s} is not a directory", .{p});
        return false;
    }
    // Anyone could then put module files there that the group loads.
    if (st.mode & 0o002 != 0) {
        warn("project directory {s} is writable by others and is not used; chmod o-w it", .{p});
        return false;
    }
    // Without it, each member's installs carry that member's own group.
    if (st.mode & 0o2000 == 0) warn("project directory {s} has no setgid bit, so installs keep the installer's group; chmod g+s it", .{p});
    return true;
}

/// The installation directory place gives, without checking a project
/// directory.
fn locate(c: Ctx, s: config.Settings) Place {
    if (s.project.value) |p| return .{ .prefix = storage.canonical(c.a, p, c.cwd) catch oom(), .project = true };
    var raw = s.prefix.value;
    if (std.mem.startsWith(u8, raw, "~/") or std.mem.eql(u8, raw, "~")) {
        const home = nonEmpty(c.env.get("HOME")) orelse die("prefix {s} needs HOME", .{raw});
        raw = std.mem.concat(c.a, u8, &.{ home, raw[1..] }) catch oom();
        if (std.mem.eql(u8, s.prefix.from, "default")) {
            if (legacyPrefix(c, home, raw)) |old| return .{ .prefix = old, .project = false };
        }
    }
    return .{ .prefix = storage.canonical(c.a, raw, c.cwd) catch oom(), .project = false };
}

/// eb-local 2.x installed into ~/.local/eessi by default. Where
/// that tree holds an install and the new default does not exist, it stays
/// in use, so installed modules do not disappear; set `prefix` to choose
/// for good. An empty ~/.local/eessi holds nothing to keep.
fn legacyPrefix(c: Ctx, home: []const u8, default_prefix: []const u8) ?[]const u8 {
    if (isDir(default_prefix)) return null;
    const old = std.fs.path.join(c.a, &.{ home, ".local", "eessi" }) catch oom();
    const versions = std.fs.path.join(c.a, &.{ old, "versions" }) catch oom();
    const own = std.fs.path.join(c.a, &.{ old, ".eb-local" }) catch oom();
    if (!isDir(versions) and !isDir(own)) return null;
    warn("using {s}, the default before eb-local 3.0; EESSI-extend and `eb-local eb` use {s}.", .{ old, default_prefix });
    cli.err("  Keep it with prefix = \"~/.local/eessi\" in ~/.config/eb-local/config.toml, or move it to {s}.\n", .{default_prefix});
    return storage.canonical(c.a, old, c.cwd) catch oom();
}

// ---- env, dev, config, profiles -------------------------------------------

fn envStrict(c: Ctx, g: Global) bool {
    if (g.env_strict) return true;
    const v = c.env.get("EB_LOCAL_ENV_STRICT") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false");
}

/// One variable of an `EnvChange`.
const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// `env --json` and `dev --json`: what the lines change in the environment of
/// the shell that evaluates them, for a shell that cannot evaluate them.
/// Shell functions and aliases (Lmod's `module`) are not variables and are
/// not in it.
const EnvChange = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8,
    /// Variables the lines add or change, by name.
    set: []const EnvVar,
    /// Variables the lines remove, by name.
    unset: []const []const u8,
};

/// Variables bash keeps for itself; they say nothing about the lines.
const shell_own = [_][]const u8{ "_", "SHLVL", "PWD", "OLDPWD", "BASH_EXECUTION_STRING" };

fn shellOwn(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "BASH_FUNC_")) return true;
    for (shell_own) |own| if (std.mem.eql(u8, name, own)) return true;
    return false;
}

fn envVarLess(_: void, x: EnvVar, y: EnvVar) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// Run `lines` in a bash child and print, as one JSON document, how its
/// environment then differs from this process's. The child's own output goes
/// to stderr, so stdout carries the document alone.
fn emitEnvChange(c: Ctx, kind: []const u8, lines: []const u8) u8 {
    const a = c.a;
    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    const script = str(a, "exec 3>&1 1>&2\n{s}\nenv -0 >&3\n", .{lines});
    const r = proc.run(a, bash, &.{ bash, "--noprofile", "--norc", "-c", script }, c.envp, .{
        .stdout_limit = 8 << 20,
        .stderr_limit = 1 << 20,
        .timeout_ms = 300_000,
    }) catch |e| {
        warn("could not run the {s} lines in bash: {s}", .{ kind, @errorName(e) });
        return 1;
    };
    if (r.stderr.len > 0) cli.put(2, r.stderr);
    if (r.term.code() != 0) {
        warn("the {s} lines failed in bash (status {d}); no change is printed", .{ kind, r.term.code() });
        return 1;
    }
    var set: std.ArrayList(EnvVar) = .empty;
    var after: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, r.stdout, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        const value = entry[eq + 1 ..];
        if (name.len == 0 or shellOwn(name)) continue;
        after.put(a, name, {}) catch oom();
        if (c.env.get(name)) |before| {
            if (std.mem.eql(u8, before, value)) continue;
        }
        set.append(a, .{ .name = name, .value = value }) catch oom();
    }
    var unset: std.ArrayList([]const u8) = .empty;
    var before_it = c.env.iterator();
    while (before_it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (shellOwn(name) or after.contains(name)) continue;
        unset.append(a, name) catch oom();
    }
    std.mem.sort(EnvVar, set.items, {}, envVarLess);
    std.mem.sort([]const u8, unset.items, {}, lessThanStr);
    jsonout.emit(a, EnvChange{ .kind = kind, .set = set.items, .unset = unset.items });
    return 0;
}

fn cmdEnv(c: Ctx, s: config.Settings, g: Global) u8 {
    const p = place(c, s);
    const lines = environmentLines(c, s, p, envStrict(c, g));
    if (g.json_out) return emitEnvChange(c, "env", lines);
    evalHint(replay(c.a, "env", s, g, p.prefix, &.{}));
    cli.put(1, lines);
    return 0;
}

/// The first and last line of the lines `dev --envrc` owns in `.envrc`.
/// What stands outside them is the user's and is kept.
const envrc_begin = "# >>> eb-local dev >>>";
const envrc_end = "# <<< eb-local dev <<<";

/// Write `eval "$(eb-local WORDS)"` between the markers of `.envrc` in the
/// working directory, for direnv: it evaluates the file in bash and gives the
/// calling shell the change, whatever that shell is, and takes it back on
/// leaving the directory. A block already there is replaced; other lines
/// stay. The program is named by its own path, since a shell that direnv
/// starts need not have eb-local on PATH.
fn writeEnvrc(c: Ctx, words: []const u8) u8 {
    const a = c.a;
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse "eb-local";
    const block = str(a, "{s} rerun `eb-local dev --envrc` to change these lines\neval \"$({s} {s})\"\n{s}\n", .{ envrc_begin, q(a, exe), words, envrc_end });
    const old: []const u8 = if (fsx.openRegular(fsx.cwd, ".envrc", true)) |opened| blk: {
        defer sys.close(opened.fd);
        break :blk fsx.readAll(a, opened.fd, 1 << 20) catch |e| die("cannot read .envrc ({s})", .{@errorName(e)});
    } else |_| "";
    const text = if (std.mem.indexOf(u8, old, envrc_begin)) |at| blk: {
        const rest = std.mem.indexOfPos(u8, old, at, envrc_end) orelse
            die(".envrc has `{s}` without `{s}`; remove that line or add the end line, then run this again", .{ envrc_begin, envrc_end });
        var end = rest + envrc_end.len;
        if (end < old.len and old[end] == '\n') end += 1;
        break :blk str(a, "{s}{s}{s}", .{ old[0..at], block, old[end..] });
    } else if (old.len == 0)
        block
    else
        str(a, "{s}{s}{s}", .{ old, if (old[old.len - 1] == '\n') "" else "\n", block });
    fsx.replaceContents(a, fsx.cwd, ".envrc", text) catch |e| die("cannot write .envrc ({s})", .{@errorName(e)});
    cli.err("eb-local: wrote .envrc in {s}; run `direnv allow` there to load it\n", .{c.cwd});
    return 0;
}

fn cmdDev(c: Ctx, s: config.Settings, g: Global, extra: []const []const u8) u8 {
    const a = c.a;
    // A module is loaded once, where it is first named; a chosen build
    // environment only last. Left at the default, the build environment that
    // comes last depends on the compilers, so one named here stays.
    const chosen = !std.mem.eql(u8, s.dev_buildenv.from, "default");
    var mods: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ s.dev_modules.value, extra }) |names| for (names) |m| {
        if (chosen and std.mem.eql(u8, m, s.dev_buildenv.value)) continue;
        for (mods.items) |seen| {
            if (std.mem.eql(u8, seen, m)) break;
        } else mods.append(a, m) catch oom();
    };
    const installed = place(c, s);
    if (g.envrc) return writeEnvrc(c, replay(a, "dev", s, g, installed.prefix, extra));
    if (!g.json_out) evalHint(replay(a, "dev", s, g, installed.prefix, extra));
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, environmentLines(c, s, installed, envStrict(c, g))) catch oom();
    // The modules the program uses first, the build environment last, so
    // its wrappers come first on PATH. When the program links, they record
    // a run path for each directory on LIBRARY_PATH, which the modules set
    // in either order, so the program runs without LD_LIBRARY_PATH.
    if (mods.items.len > 0) {
        out.appendSlice(a, "module load") catch oom();
        for (mods.items) |m| out.appendSlice(a, str(a, " {s}", .{q(a, m)})) catch oom();
        out.append(a, '\n') catch oom();
    }
    // A previous dev may have put RPATH wrappers first on PATH. Drop that
    // directory before this dev chooses again, or a later build environment
    // stays hidden behind the wrappers.
    out.appendSlice(a, drop_rpath_wrappers) catch oom();
    out.appendSlice(a, buildenvLines(c, s)) catch oom();
    out.appendSlice(a, host_ca_bundle) catch oom();
    // A program linked here belongs to this shell's CPU (and GPU) target, so
    // its install directory names them; the shell fills them in once EESSI
    // has picked them.
    const dev_root = std.fs.path.join(a, &.{ installed.prefix, "dev" }) catch oom();
    out.appendSlice(a, str(a, "export EB_LOCAL_DEV_PREFIX={s}\"/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR${{EESSI_ACCELERATOR_TARGET:+/$EESSI_ACCELERATOR_TARGET}}\"\n", .{q(a, dev_root)})) catch oom();
    if (g.json_out) return emitEnvChange(c, "dev", out.items);
    cli.put(1, out.items);
    if (nonEmpty(c.env.get("LD_LIBRARY_PATH")) != null) {
        warn("LD_LIBRARY_PATH is set in this shell; programs built here do not need it,", .{});
        cli.err("  and it can mix host libraries into EESSI's. Unset it unless you know you need it.\n", .{});
    }
    // Only the GCC build environment is known to lack LLVM wrappers; a site's
    // own buildenv may wrap clang under any name.
    // With the default, buildenvLines picks the build environment for the
    // compilers; a chosen GCC one is loaded as it is, so say what it misses.
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default") and gccBuildenv(s.dev_buildenv.value)) {
        for (mods.items) |m| if (llvmToolchain(m)) |tc| {
            warn("{s} belongs to the {s} toolchain, but {s} wraps only the GCC compilers;", .{ m, tc, s.dev_buildenv.value });
            cli.err("  clang and flang get no run paths for its libraries. Name an lfoss build environment with --buildenv.\n", .{});
            break;
        };
    }
    return 0;
}

/// A build environment of the GCC toolchains, as EasyBuild names them.
fn gccBuildenv(module: []const u8) bool {
    if (llvmToolchain(module) != null) return false;
    for ([_][]const u8{ "foss", "gompi", "gfbf", "GCC", "GCCcore" }) |tc| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, module, from, tc)) |at| {
            const end = at + tc.len;
            const before_ok = at == 0 or module[at - 1] == '/' or module[at - 1] == '-';
            const after_ok = end == module.len or module[end] == '/' or module[end] == '-';
            if (before_ok and after_ok) return true;
            from = at + 1;
        }
    }
    return false;
}

/// The LLVM toolchain of the lfoss hierarchy a module name belongs to, as
/// EasyBuild names it in the module's version suffix, if any.
fn llvmToolchain(module: []const u8) ?[]const u8 {
    for ([_][]const u8{ "llvm-compilers", "lompi", "lfbf", "lfoss", "lmpflf" }) |tc| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, module, from, tc)) |at| {
            const end = at + tc.len;
            const before_ok = at == 0 or module[at - 1] == '/' or module[at - 1] == '-';
            const after_ok = end == module.len or module[end] == '/' or module[end] == '-';
            if (before_ok and after_ok) return tc;
            from = at + 1;
        }
    }
    return null;
}

test "onlyXalt is XALT's init library and nothing else" {
    try std.testing.expect(onlyXalt("/opt/xalt/current/lib64/libxalt_init.so:"));
    try std.testing.expect(onlyXalt("/opt/xalt/lib64/libxalt_init.so /usr/lib/xalt/libxalt_init.so.1"));
    try std.testing.expect(!onlyXalt(""));
    try std.testing.expect(!onlyXalt(":"));
    try std.testing.expect(!onlyXalt("/opt/xalt/lib64/libxalt_init.so:/home/u/hack.so"));
    try std.testing.expect(!onlyXalt("/home/u/libxalt.so"));
}

test "llvmToolchain names the lfoss hierarchy and nothing else" {
    try std.testing.expectEqualStrings("lfoss", llvmToolchain("ScaLAPACK/2.2.2-lfoss-2026.1-fb").?);
    try std.testing.expectEqualStrings("lompi", llvmToolchain("FFTW.MPI/3.3.10-lompi-2026.1").?);
    try std.testing.expectEqualStrings("llvm-compilers", llvmToolchain("llvm-compilers/21.1.8").?);
    try std.testing.expectEqualStrings("lfbf", llvmToolchain("lfbf/2026.1").?);
    try std.testing.expect(llvmToolchain("FFTW/3.3.10-GCC-15.2.0") == null);
    try std.testing.expect(llvmToolchain("buildenv/default-foss-2026.1") == null);
    try std.testing.expect(llvmToolchain("Xlfossy/1.0") == null);
    try std.testing.expectEqualStrings("lmpflf", llvmToolchain("X/1.0-lmpflf-2026.1").?);
}

test "gccBuildenv names the GCC build environments only" {
    try std.testing.expect(gccBuildenv("buildenv/default-foss-2026.1"));
    try std.testing.expect(gccBuildenv("buildenv/default-foss-2026.1-CUDA-13.3.0"));
    try std.testing.expect(gccBuildenv("buildenv/default-GCC-15.2.0"));
    try std.testing.expect(gccBuildenv("buildenv/foss-2026.1"));
    try std.testing.expect(gccBuildenv("foss/2026.1"));
    try std.testing.expect(gccBuildenv("GCCcore/15.2.0"));
    try std.testing.expect(!gccBuildenv("mygcc/1.0"));
    try std.testing.expect(!gccBuildenv("buildenv/default-lfoss-2026.1"));
    try std.testing.expect(!gccBuildenv("buildenv/site-llvm"));
    try std.testing.expect(!gccBuildenv("buildenv/default-intel-2026.1"));
}

/// Remove the wrapper directory a previous `dev` prepended. The new dev
/// adds its own afterwards when it still needs wrappers.
const drop_rpath_wrappers =
    \\if [ -n "${EB_LOCAL_RPATH_WRAPPERS-}" ]; then
    \\    _eb_local_path=
    \\    _eb_local_rest=$PATH
    \\    while [ -n "$_eb_local_rest" ]; do
    \\        case $_eb_local_rest in
    \\            *:*) _eb_local_ent=${_eb_local_rest%%:*}; _eb_local_rest=${_eb_local_rest#*:} ;;
    \\            *) _eb_local_ent=$_eb_local_rest; _eb_local_rest= ;;
    \\        esac
    \\        if [ "$_eb_local_ent" != "$EB_LOCAL_RPATH_WRAPPERS" ]; then
    \\            _eb_local_path=${_eb_local_path:+$_eb_local_path:}$_eb_local_ent
    \\        fi
    \\    done
    \\    PATH=$_eb_local_path
    \\    export PATH
    \\    unset EB_LOCAL_RPATH_WRAPPERS _eb_local_path _eb_local_rest _eb_local_ent
    \\fi
    \\
;

/// Name the host's CA bundle for the tools that take it from a variable.
/// EESSI's cargo and curl look for the bundle where their own distribution
/// keeps it. A host that keeps it elsewhere has no file there, and they
/// refuse every HTTPS request. A variable the shell already set is kept.
const host_ca_bundle =
    \\if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then
    \\    for _eb_local_ca in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
    \\        if [ -r "$_eb_local_ca" ]; then
    \\            [ -n "${SSL_CERT_FILE-}" ] || export SSL_CERT_FILE="$_eb_local_ca"
    \\            [ -n "${CARGO_HTTP_CAINFO-}" ] || export CARGO_HTTP_CAINFO="$_eb_local_ca"
    \\            break
    \\        fi
    \\    done
    \\    unset _eb_local_ca
    \\fi
    \\
;

/// The lines that load the build environment. A dev.buildenv the caller
/// chose is loaded as it is. The default depends on the compilers the
/// modules brought in, which only the shell knows after it loads them: the
/// family's buildenv when Lmod has it, else the GCC one for CUDA (nvcc
/// links through gcc), else eb-local's RPATH wrappers, so nothing links
/// without run paths. Whichever loads, a clang that no wrapper covers then
/// gets one: the LLVM module sets EBROOTLLVM, not llvm-compilers' variable,
/// so its clang comes with the GCC build environment, which does not wrap it.
fn buildenvLines(c: Ctx, s: config.Settings) []const u8 {
    const a = c.a;
    const gcc = q(a, s.dev_buildenv.value);
    var exe_buf: [sys.path_max]u8 = undefined;
    const exe = q(a, selfExe(&exe_buf) orelse tool);
    const unwrapped = str(a, "eval \"$({s} rpath-wrappers --unwrapped)\"\n", .{exe});
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default")) return str(a, "module load {s}\n{s}", .{ gcc, unwrapped });
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    add(a, &out, "eb_local_family=gcc\n");
    for (config.families) |f|
        add(a, &out, str(a, "if [ -n \"${{{s}-}}\" ]; then eb_local_family={s}; fi\n", .{ f.ebroot, f.name }));
    add(a, &out, "case $eb_local_family in\n");
    for (config.families, s.buildenv_for) |f, b|
        add(a, &out, str(a, "    {s}) eb_local_buildenv={s} ;;\n", .{ f.name, if (b.value.len == 0) "''" else q(a, b.value) }));
    add(a, &out, "    *) eb_local_buildenv= ;;\nesac\n");
    add(a, &out, str(a,
        \\if [ "$eb_local_family" = gcc ]; then
        \\    module load {s}
        \\elif [ -n "$eb_local_buildenv" ] && module is-avail "$eb_local_buildenv" >/dev/null 2>&1; then
        \\    module load "$eb_local_buildenv"
        \\elif [ "$eb_local_family" = cuda ]; then
        \\    module load {s}
        \\else
        \\    eval "$({s} rpath-wrappers --for "$eb_local_family")"
        \\fi
        \\unset eb_local_family eb_local_buildenv
        \\
    , .{ gcc, gcc, exe }));
    add(a, &out, unwrapped);
    return out.items;
}

/// With `only_unwrapped`, the wrappers are for the compilers that find
/// their linker themselves, where no wrapper of eb-local's or of a build
/// environment's comes first on PATH, and none at all is fine.
fn cmdRpathWrappers(c: Ctx, family: []const u8, only_unwrapped: bool) u8 {
    const a = c.a;
    const path = c.env.get("PATH") orelse "";
    const found = (if (only_unwrapped) rpath.unwrapped(a, path, &rpath.self_linking) else rpath.present(a, path)) catch oom();
    if (found.len == 0) {
        if (only_unwrapped) return 0;
        warn("no compiler or linker on PATH to wrap", .{});
        return 1;
    }
    const dir = rpath.directory(a, c.env, found) catch |e| switch (e) {
        error.NoCacheDir => die("rpath-wrappers needs an absolute XDG_CACHE_HOME or HOME", .{}),
        else => die("cannot work out the wrapper directory ({s})", .{storage.describeError(e)}),
    };
    rpath.write(a, dir, found) catch |e| die("cannot write RPATH wrappers in {s} ({s})", .{ dir, storage.describeError(e) });
    const names = std.mem.join(a, " ", found) catch oom();
    if (only_unwrapped) {
        warn("the build environment does not wrap {s};", .{names});
        cli.err("  RPATH wrappers for it come first ({s}), so what it links has run paths.\n", .{dir});
    } else if (family.len > 0) {
        warn("no build environment module for the {s} compilers is available;", .{family});
        cli.err("  RPATH wrappers for {s} stand in for it ({s}).\n", .{ names, dir });
    }
    cli.put(1, str(a, "export PATH={s}:\"$PATH\"\nexport EB_LOCAL_RPATH_WRAPPERS={s}\n", .{ q(a, dir), q(a, dir) }));
    return 0;
}

// ---- check ----------------------------------------------------------------

const CheckFileJson = struct {
    path: []const u8,
    machine: []const u8,
    problems: std.ArrayList([]const u8) = .empty,
};

const CheckFileOut = struct {
    path: []const u8,
    machine: []const u8,
    problems: []const []const u8,
};

const CheckReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "check",
    problem_count: usize,
    unreadable: bool,
    elf_count: usize,
    files: []const CheckFileOut,
};

const Check = struct {
    problems: usize = 0,
    json: bool = false,
    recursive: bool = false,
    files: std.ArrayList(CheckFileJson) = .empty,
    audited: std.StringHashMapUnmanaged(void) = .empty,
    queued: std.StringHashMapUnmanaged(void) = .empty,
    queue: std.ArrayList([]const u8) = .empty,

    fn canonicalKey(a: Allocator, path: []const u8) []const u8 {
        var buf: [sys.path_max]u8 = undefined;
        return a.dupe(u8, fsx.realpath(fsx.cwd, path, &buf) catch path) catch oom();
    }

    fn isAudited(k: *Check, a: Allocator, path: []const u8) bool {
        return k.audited.contains(canonicalKey(a, path));
    }

    fn markAudited(k: *Check, a: Allocator, path: []const u8) void {
        k.audited.put(a, canonicalKey(a, path), {}) catch oom();
    }

    fn enqueue(k: *Check, a: Allocator, path: []const u8) void {
        if (!k.recursive) return;
        const key = canonicalKey(a, path);
        if (k.audited.contains(key) or k.queued.contains(key)) return;
        k.queued.put(a, key, {}) catch oom();
        k.queue.append(a, a.dupe(u8, path) catch oom()) catch oom();
    }

    fn beginFile(k: *Check, a: Allocator, path: []const u8, machine: []const u8) void {
        if (!k.json) return;
        k.files.append(a, .{ .path = path, .machine = machine, .problems = .empty }) catch oom();
    }

    fn problem(k: *Check, a: Allocator, comptime fmt: []const u8, args: anytype) void {
        if (!k.json) say("  problem: " ++ fmt, args);
        k.problems += 1;
        if (!k.json) return;
        const msg = std.fmt.allocPrint(a, fmt, args) catch oom();
        if (k.files.items.len == 0) return;
        k.files.items[k.files.items.len - 1].problems.append(a, msg) catch oom();
    }
};

/// Where the loader looks for a library named without a slash, in its order.
const Search = struct {
    dirs: std.ArrayList([]const u8) = .empty,
    /// Which list each directory came from, for the report.
    whence: std.ArrayList([]const u8) = .empty,

    const Hit = struct { path: []const u8, why: []const u8 };

    /// The first directory holding `name`, skipping LD_LIBRARY_PATH unless
    /// `env` is set.
    fn find(sr: Search, a: Allocator, name: []const u8, env: bool) ?Hit {
        for (sr.dirs.items, sr.whence.items) |d, why| {
            if (!env and std.mem.eql(u8, why, "LD_LIBRARY_PATH")) continue;
            const p = std.fs.path.join(a, &.{ d, name }) catch oom();
            if (isFile(p)) return .{ .path = p, .why = why };
        }
        return null;
    }

    fn add(sr: *Search, a: Allocator, list: ?[]const u8, origin: []const u8, why: []const u8) void {
        var it = std.mem.splitScalar(u8, list orelse return, ':');
        while (it.next()) |d| if (d.len > 0) {
            sr.dirs.append(a, elfcheck.expandOrigin(a, d, origin) catch oom()) catch oom();
            sr.whence.append(a, why) catch oom();
        };
    }
};

fn isFile(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, true) catch return false;
    return st.isReg();
}

fn isDir(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, true) catch return false;
    return st.isDir();
}

fn resolveRootPath(a: Allocator, root: []const u8, path: []const u8) []const u8 {
    if (std.mem.eql(u8, root, "/") or storage.under(path, root)) return path;
    return std.fs.path.join(a, &.{ root, path }) catch oom();
}

/// The directories the loader under `root` searches last: those its
/// ld.so.conf names, one level of `include DIR/*.conf` deep, then its
/// built-in ones. The loader reads a cache built from the same list.
fn loaderDirs(a: Allocator, root: []const u8) []const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    var includes: std.ArrayList([]const u8) = .empty;
    const conf = std.fs.path.join(a, &.{ root, "etc/ld.so.conf" }) catch oom();
    if (readSmall(a, conf)) |text| elfcheck.parseLdSoConf(a, text, &dirs, &includes) catch oom();
    for (includes.items) |pat| {
        // Only the DIR/*.SUFFIX (or *.SUFFIX under etc/) form; anything else is skipped.
        const slash = std.mem.lastIndexOfScalar(u8, pat, '/');
        const base = if (slash) |s| pat[s + 1 ..] else pat;
        if (!std.mem.startsWith(u8, base, "*") or std.mem.indexOfAny(u8, base[1..], "*?[") != null) continue;
        const dir = if (slash) |s| blk: {
            const raw_dir = if (s == 0) "/" else pat[0..s];
            break :blk if (raw_dir[0] == '/')
                resolveRootPath(a, root, raw_dir)
            else
                std.fs.path.join(a, &.{ root, "etc", raw_dir }) catch oom();
        } else std.fs.path.join(a, &.{ root, "etc" }) catch oom();
        const fd = fsx.openDir(fsx.cwd, dir, true) catch continue;
        defer sys.close(fd);
        var names: std.ArrayList([]const u8) = .empty;
        var it = fsx.DirIter.init(a, fd) catch oom();
        while (it.next() catch null) |e| if (std.mem.endsWith(u8, e.name, base[1..]))
            names.append(a, a.dupe(u8, e.name) catch oom()) catch oom();
        std.mem.sort([]const u8, names.items, {}, lessThanStr);
        var none: std.ArrayList([]const u8) = .empty;
        for (names.items) |n| {
            const p = std.fs.path.join(a, &.{ dir, n }) catch oom();
            if (readSmall(a, p)) |text| elfcheck.parseLdSoConf(a, text, &dirs, &none) catch oom();
        }
    }
    for (dirs.items) |*d| d.* = resolveRootPath(a, root, d.*);
    for ([_][]const u8{ "lib64", "usr/lib64", "lib", "usr/lib" }) |sub|
        dirs.append(a, std.fs.path.join(a, &.{ root, sub }) catch oom()) catch oom();
    return dirs.items;
}

fn lessThanStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn readSmall(a: Allocator, path: []const u8) ?[]const u8 {
    const f = fsx.openRegular(fsx.cwd, path, true) catch return null;
    defer sys.close(f.fd);
    return fsx.readAll(a, f.fd, 64 * 1024) catch null;
}

fn checkStatus(c: Ctx, k: *Check, unreadable: bool, elfs: usize) u8 {
    if (k.json) {
        const a = c.a;
        var outs: std.ArrayList(CheckFileOut) = .empty;
        for (k.files.items) |f| {
            outs.append(a, .{ .path = f.path, .machine = f.machine, .problems = f.problems.items }) catch oom();
        }
        const report: CheckReport = .{
            .problem_count = k.problems,
            .unreadable = unreadable,
            .elf_count = elfs,
            .files = outs.items,
        };
        jsonout.emit(a, report);
    } else if (k.problems > 0) {
        say("eb-local check: {d} problem(s)", .{k.problems});
    } else if (unreadable) {
        return 2;
    } else say("eb-local check: no problems", .{});
    if (k.problems > 0) return 1;
    if (unreadable) return 2;
    return 0;
}

var suppress_check_stdout: bool = false;

/// Print the header for `path` once, so a quiet audit still names the file
/// a problem belongs to.
fn showHeader(shown: *bool, path: []const u8, machine: []const u8) void {
    if (suppress_check_stdout or shown.*) return;
    say("{s}: {s}", .{ path, machine });
    shown.* = true;
}

/// The report `check` prints for one ELF file already parsed. `quiet`
/// skips the lines that are not problems; the problem lines are the same
/// either way.
fn reportElf(c: Ctx, k: *Check, path: []const u8, elf: elfcheck.Elf, quiet: bool) void {
    const a = c.a;
    const raw_target = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR"));
    const target = if (raw_target) |rt| blk: {
        const trimmed = std.mem.trimEnd(u8, rt, "/");
        break :blk if (trimmed.len > 0) trimmed else rt;
    } else null;
    const raw_eprefix = nonEmpty(c.env.get("EESSI_EPREFIX"));
    const eprefix = if (raw_eprefix) |ep| blk: {
        const trimmed = std.mem.trimEnd(u8, ep, "/");
        break :blk if (trimmed.len > 0) trimmed else ep;
    } else null;
    const machine = elfcheck.machineName(elf.machine);
    if (k.json) k.beginFile(a, path, machine);
    var shown = false;
    if (!quiet) showHeader(&shown, path, machine);
    if (elf.machine != elfcheck.hostMachine()) {
        showHeader(&shown, path, machine);
        k.problem(a, "built for {s}; this node is {s}", .{ machine, elfcheck.machineName(elfcheck.hostMachine()) });
    }
    var buf: [sys.path_max]u8 = undefined;
    const real = fsx.realpath(fsx.cwd, path, &buf) catch path;
    const origin = a.dupe(u8, std.fs.path.dirname(real) orelse "/") catch oom();
    if (elf.interp) |interp| {
        if (!quiet) say("  loader   {s}", .{interp});
        if (eprefix) |ep| if (!storage.under(interp, ep)) {
            showHeader(&shown, path, machine);
            k.problem(a, "the loader is the host's, not the compatibility layer's under {s}", .{ep});
        };
    }
    if (elf.rpath) |r| if (!quiet) say("  RPATH    {s}", .{r});
    if (elf.runpath) |r| {
        if (!quiet) say("  RUNPATH  {s}", .{r});
        showHeader(&shown, path, machine);
        k.problem(a, "RUNPATH, which LD_LIBRARY_PATH overrides and the libraries' own dependencies ignore; link with --disable-new-dtags for RPATH", .{});
    }
    if (elf.interp == null and elf.needed.len == 0) {
        if (!quiet) say("  static: no loader and no libraries", .{});
        return;
    }

    var sr: Search = .{};
    if (elf.runpath == null) sr.add(a, elf.rpath, origin, "RPATH");
    sr.add(a, c.env.get("LD_LIBRARY_PATH"), origin, "LD_LIBRARY_PATH");
    sr.add(a, elf.runpath, origin, "RUNPATH");
    // The loader's own directories: <root>/lib64 and the rest, where
    // <root> is the compatibility layer for its loader, / for the host's.
    const root = if (elf.interp) |i| (std.fs.path.dirname(std.fs.path.dirname(i) orelse "/") orelse "/") else "/";
    for (loaderDirs(a, root)) |d| {
        sr.dirs.append(a, d) catch oom();
        sr.whence.append(a, "the loader's directories") catch oom();
    }

    var seen_targets: std.ArrayList([]const u8) = .empty;
    for (sr.dirs.items, sr.whence.items) |d, why| {
        if (std.mem.eql(u8, why, "the loader's directories")) continue;
        const t = elfcheck.targetOf(d) orelse continue;
        const want = target orelse continue;
        if (std.mem.eql(u8, t, want)) continue;
        for (seen_targets.items) |s0| {
            if (std.mem.eql(u8, s0, t)) break;
        } else {
            seen_targets.append(a, t) catch oom();
            showHeader(&shown, path, machine);
            k.problem(a, "run paths into the {s} software tree; this shell is {s}: build it again on this node type", .{ t, want });
        }
    }

    for (elf.needed) |n| {
        if (std.mem.indexOfScalar(u8, n, '/') != null) {
            const needed_path = elfcheck.expandOrigin(a, n, origin) catch oom();
            if (!quiet) {
                if (std.mem.eql(u8, needed_path, n))
                    say("  needs    {s}", .{n})
                else
                    say("  needs    {s} => {s}", .{ n, needed_path });
            }
            if (!isFile(needed_path)) {
                showHeader(&shown, path, machine);
                k.problem(a, "{s} does not exist", .{needed_path});
            } else k.enqueue(a, needed_path);
            continue;
        }
        // The job may run without this shell's LD_LIBRARY_PATH, so the
        // pick without it is the one that counts.
        const clean = sr.find(a, n, false);
        const with = sr.find(a, n, true);
        const h = clean orelse {
            showHeader(&shown, path, machine);
            if (with) |w| {
                if (!quiet) say("  needs    {s} => {s}   [LD_LIBRARY_PATH]", .{ n, w.path });
                k.problem(a, "{s} is found only through LD_LIBRARY_PATH", .{n});
            } else {
                if (!quiet) say("  needs    {s} => not found", .{n});
                k.problem(a, "{s} is not found", .{n});
            }
            continue;
        };
        if (!quiet) say("  needs    {s} => {s}   [{s}]", .{ n, h.path, h.why });
        if (!quiet) if (with) |w| if (!std.mem.eql(u8, w.path, h.path))
            say("           LD_LIBRARY_PATH in this shell picks {s} instead", .{w.path});
        if (eprefix != null and elfcheck.isHostPath(h.path)) {
            showHeader(&shown, path, machine);
            k.problem(a, "{s} comes from the host, not from EESSI", .{n});
        }
        k.enqueue(a, h.path);
    }
}

/// Open `path` and report it. A tree audit (`skip_non_elf`) skips a file
/// that is not 64-bit little-endian ELF; naming the file does not.
/// True when an ELF file was audited.
fn auditFile(c: Ctx, k: *Check, path: []const u8, quiet: bool, skip_non_elf: bool, unreadable: *bool) bool {
    const opened = fsx.openRegular(fsx.cwd, path, !skip_non_elf) catch |e| {
        warn("cannot open {s} ({s})", .{ path, @errorName(e) });
        unreadable.* = true;
        return false;
    };
    defer sys.close(opened.fd);
    const elf = elfcheck.parse(c.a, opened.fd) catch |e| {
        if (skip_non_elf and (e == error.NotElf64 or e == error.Unsupported)) return false;
        switch (e) {
            error.NotElf64, error.Unsupported => warn("{s} is not a 64-bit little-endian ELF file", .{path}),
            else => warn("cannot read {s} as ELF ({s})", .{ path, @errorName(e) }),
        }
        unreadable.* = true;
        return false;
    };
    k.markAudited(c.a, path);
    reportElf(c, k, path, elf, quiet or k.json);
    return true;
}

fn drainCheckQueue(c: Ctx, k: *Check, quiet: bool, unreadable: *bool, elfs: *usize) void {
    var idx: usize = 0;
    while (idx < k.queue.items.len) : (idx += 1) {
        const path = k.queue.items[idx];
        if (k.isAudited(c.a, path)) continue;
        if (auditFile(c, k, path, quiet, false, unreadable)) elfs.* += 1;
    }
}

fn cmdCheck(c: Ctx, files: []const []const u8, quiet: bool, json: bool, recursive: bool) u8 {
    if (files.len == 0) die("check needs one or more programs or libraries", .{});
    suppress_check_stdout = json;
    defer suppress_check_stdout = false;
    var k: Check = .{ .json = json, .recursive = recursive };
    var unreadable = false;
    var elfs: usize = 0;
    for (files) |f| {
        if (k.isAudited(c.a, f)) continue;
        if (auditFile(c, &k, f, quiet, false, &unreadable)) elfs += 1;
    }
    drainCheckQueue(c, &k, quiet, &unreadable, &elfs);
    return checkStatus(c, &k, unreadable, elfs);
}

/// How deep a tree audit walks. A module or dev tree is far shallower.
const check_walk_max = 64;

/// Every regular file under `root`, not through a symbolic link. A file
/// that is not ELF is skipped. `elfs` counts the files that were audited.
fn walkElfs(c: Ctx, root: []const u8, quiet: bool, k: *Check, unreadable: *bool, elfs: *usize, depth: usize) void {
    if (depth > check_walk_max) {
        warn("{s} is too deep to check", .{root});
        unreadable.* = true;
        return;
    }
    const fd = fsx.openDir(fsx.cwd, root, false) catch |e| {
        warn("cannot open {s} ({s})", .{ root, @errorName(e) });
        unreadable.* = true;
        return;
    };
    defer sys.close(fd);
    var names: std.ArrayList([]const u8) = .empty;
    var it = fsx.DirIter.init(c.a, fd) catch oom();
    while (true) {
        const entry = it.next() catch |e| {
            warn("cannot read {s} ({s})", .{ root, @errorName(e) });
            unreadable.* = true;
            break;
        } orelse break;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        names.append(c.a, c.a.dupe(u8, entry.name) catch oom()) catch oom();
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    for (names.items) |name| {
        const st = fsx.statAt(fd, name, false) catch |e| {
            const path = std.fs.path.join(c.a, &.{ root, name }) catch oom();
            warn("cannot stat {s} ({s})", .{ path, @errorName(e) });
            unreadable.* = true;
            continue;
        };
        if (st.isLink()) continue;
        const path = std.fs.path.join(c.a, &.{ root, name }) catch oom();
        if (st.isDir()) {
            walkElfs(c, path, quiet, k, unreadable, elfs, depth + 1);
        } else if (st.isReg()) {
            if (auditFile(c, k, path, quiet, true, unreadable)) elfs.* += 1;
        }
    }
}

/// The dev tree `dev` names: `EB_LOCAL_DEV_PREFIX` when the shell set it,
/// otherwise `<prefix>/dev/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR`, with
/// `$EESSI_ACCELERATOR_TARGET` appended when that is set.
fn devTree(c: Ctx, s: config.Settings) []const u8 {
    if (nonEmpty(c.env.get("EB_LOCAL_DEV_PREFIX"))) |raw|
        return storage.canonical(c.a, raw, c.cwd) catch oom();
    const eessi_version = nonEmpty(c.env.get("EESSI_VERSION")) orelse
        die("check --dev needs EB_LOCAL_DEV_PREFIX, or EESSI_VERSION and EESSI_SOFTWARE_SUBDIR", .{});
    const sub = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR")) orelse
        die("check --dev needs EB_LOCAL_DEV_PREFIX, or EESSI_VERSION and EESSI_SOFTWARE_SUBDIR", .{});
    const dev_root = storage.canonical(c.a, std.fs.path.join(c.a, &.{ place(c, s).prefix, "dev" }) catch oom(), c.cwd) catch oom();
    const base = std.fs.path.join(c.a, &.{ dev_root, eessi_version, sub }) catch oom();
    const raw = if (nonEmpty(c.env.get("EESSI_ACCELERATOR_TARGET"))) |accel|
        std.fs.path.join(c.a, &.{ base, accel }) catch oom()
    else
        base;
    const resolved = storage.canonical(c.a, raw, c.cwd) catch oom();
    if (!storage.under(resolved, dev_root) or std.mem.eql(u8, resolved, dev_root))
        die("check --dev: {s} leaves {s}", .{ resolved, dev_root });
    return resolved;
}

const CheckMode = enum { module, dev, prefix };

/// Audit every ELF file in the installations `--module` names, in the dev
/// tree, or under `--prefix`. `s` is set for a module or the dev tree.
fn cmdCheckTree(c: Ctx, s: ?config.Settings, mode: CheckMode, modules: []const []const u8, prefix_dir: []const u8, quiet: bool, json: bool, recursive: bool) u8 {
    const a = c.a;
    var roots: std.ArrayList([]const u8) = .empty;
    switch (mode) {
        .prefix => {
            const dir = storage.canonical(a, prefix_dir, c.cwd) catch oom();
            if (!isDir(dir)) die("check --prefix needs a directory; {s} is not one", .{dir});
            roots.append(a, dir) catch oom();
        },
        .dev => {
            const dir = devTree(c, s.?);
            if (!isDir(dir)) die("check --dev: {s} is not a directory", .{dir});
            roots.append(a, dir) catch oom();
        },
        .module => {
            if (modules.len == 0) die("check --module needs NAME/VERSION, as module avail shows it", .{});
            const p = place(c, s.?);
            const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
            if (fsx.statAt(fsx.cwd, versions, false)) |st| {
                if (st.isLink() or !literalPath(c, versions)) die("{s} is reached through a symbolic link; check leaves it alone.", .{versions});
            } else |_| die("nothing is installed in {s}", .{p.prefix});
            var found: Found = .{};
            for (modules) |m| {
                if (!config.validModule(m)) die("'{s}' is not a module name", .{m});
                var parts = std.mem.splitScalar(u8, m, '/');
                const name = parts.next().?;
                const ver = parts.next() orelse die("check --module needs NAME/VERSION; '{s}' has no version", .{m});
                if (parts.next() != null) die("check --module needs NAME/VERSION; '{s}' has more parts", .{m});
                const before = found.installs.items.len;
                findInstalls(c, versions, name, ver, null, &found, 0);
                if (found.installs.items.len == before) die("{s} is not installed in {s}", .{ m, p.prefix });
            }
            for (found.installs.items) |dir| {
                for (roots.items) |seen| {
                    if (std.mem.eql(u8, seen, dir)) break;
                } else roots.append(a, dir) catch oom();
            }
        },
    }
    suppress_check_stdout = json;
    defer suppress_check_stdout = false;
    var k: Check = .{ .json = json, .recursive = recursive };
    var unreadable = false;
    var elfs: usize = 0;
    for (roots.items) |root| walkElfs(c, root, quiet, &k, &unreadable, &elfs, 0);
    drainCheckQueue(c, &k, quiet, &unreadable, &elfs);
    if (elfs == 0 and !quiet and !unreadable and !json) say("eb-local check: no ELF files", .{});
    return checkStatus(c, &k, unreadable, elfs);
}

const ConfigSetting = struct { key: []const u8, value: []const u8, from: []const u8 };
const ConfigSecretJson = struct { name: []const u8, source: []const u8, from: []const u8, status: []const u8, detail: ?[]const u8 = null };
const ConfigReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "config",
    profile: []const u8,
    check: bool,
    settings: []const ConfigSetting,
    secrets: []const ConfigSecretJson,
    check_failed: bool,
};

fn cmdConfig(c: Ctx, s: config.Settings, check: bool, json: bool) u8 {
    const a = c.a;
    const p = locate(c, s);
    var settings: std.ArrayList(ConfigSetting) = .empty;
    var secrets_json: std.ArrayList(ConfigSecretJson) = .empty;
    const row = struct {
        fn f(st: *std.ArrayList(ConfigSetting), al: Allocator, json_out: bool, key: []const u8, value: []const u8, from: []const u8) void {
            if (json_out) {
                st.append(al, .{ .key = key, .value = value, .from = from }) catch oom();
            } else {
                say("{s: <28} {s}   [{s}]", .{ key, value, from });
            }
        }
    }.f;
    const profile = s.profile orelse "(none)";
    if (json) settings.append(a, .{ .key = "profile", .value = profile, .from = "option" }) catch oom() else say("{s: <28} {s}", .{ "profile", profile });
    if (p.project) row(&settings, a, json, "project", p.prefix, s.project.from) else row(&settings, a, json, "prefix", p.prefix, s.prefix.from);
    row(&settings, a, json, "stack.module", s.stack_module.value, s.stack_module.from);
    row(&settings, a, json, "stack.extend", s.extend_module.value, s.extend_module.from);
    row(&settings, a, json, "dev.buildenv", s.dev_buildenv.value, s.dev_buildenv.from);
    for (config.families, s.buildenv_for) |f, b|
        row(&settings, a, json, str(a, "dev.buildenv_for.{s}", .{f.name}), if (b.value.len == 0) "(none: RPATH wrappers)" else b.value, b.from);
    const mods = std.mem.join(a, " ", s.dev_modules.value) catch oom();
    row(&settings, a, json, "dev.modules", if (mods.len == 0) "(none)" else mods, s.dev_modules.from);
    row(&settings, a, json, "build.allocation_hint", if (s.allocation_hint.value.len == 0) "(none)" else s.allocation_hint.value, s.allocation_hint.from);
    const tcs = std.mem.join(a, " ", s.site_toolchains.value) catch oom();
    row(&settings, a, json, "build.site_toolchains", if (tcs.len == 0) "(none)" else tcs, s.site_toolchains.from);
    const types = nodeTypes(s);
    if (types.len == 0) row(&settings, a, json, "build.node_types", "(none)", s.node_types.from);
    for (types) |t| row(&settings, a, json, str(a, "build.node_types.{s}", .{t.name}), t.sbatch, t.from);
    if (s.build_secrets.value) |names| {
        row(&settings, a, json, "build.secrets", if (names.len == 0) "(none)" else std.mem.join(a, " ", names) catch oom(), s.build_secrets.from);
    } else row(&settings, a, json, "build.secrets", "(every secret)", s.build_secrets.from);
    row(&settings, a, json, "build.clear_foreign_prefixes", if (s.clear_foreign_prefixes.value) "true" else "false", s.clear_foreign_prefixes.from);
    const approved = std.mem.join(a, " ", s.approved_prefixes.value) catch oom();
    row(&settings, a, json, "doctor.approved_prefixes", if (approved.len == 0) "(none)" else approved, s.approved_prefixes.from);
    row(&settings, a, json, "doctor.cvmfs_parallel", str(a, "{d}", .{s.cvmfs_parallel.value}), s.cvmfs_parallel.from);
    const transports = std.mem.join(a, " ", s.mpi_transports.value) catch oom();
    row(&settings, a, json, "doctor.mpi_transports", if (transports.len == 0) "(none)" else transports, s.mpi_transports.from);
    row(&settings, a, json, "clean.trash", @tagName(s.trash.value), s.trash.from);
    row(&settings, a, json, "clean.logs_older_than_days", str(a, "{d}", .{s.logs_older_than_days.value}), s.logs_older_than_days.from);
    row(&settings, a, json, "nimvault.program", if (s.nimvault_program.value.len == 0) "(nimvault on PATH)" else s.nimvault_program.value, s.nimvault_program.from);
    row(&settings, a, json, "nimvault.vault", if (s.nimvault_vault.value.len == 0) "(nimvault finds it)" else s.nimvault_vault.value, s.nimvault_vault.from);
    row(&settings, a, json, "storage.node_local_root", if (s.node_local_root.value.len == 0) "(not set)" else s.node_local_root.value, s.node_local_root.from);
    row(&settings, a, json, "storage.node_local_mount", s.node_local_mount.value, s.node_local_mount.from);
    row(&settings, a, json, "storage.node_local_fstype", s.node_local_fstype.value, s.node_local_fstype.from);
    const scratch = std.mem.join(a, " ", s.shared_scratch.value) catch oom();
    row(&settings, a, json, "storage.shared_scratch", if (scratch.len == 0) "(none)" else scratch, s.shared_scratch.from);
    if (s.eessi.items.len == 0) {
        if (!json) say("{s: <28} (none)", .{"eessi"});
    } else for (s.eessi.items) |v| row(&settings, a, json, str(a, "eessi.{s}", .{v.name}), q(a, v.value), v.from);
    var failed = false;
    if (s.secrets.items.len == 0) {
        if (!json) say("{s: <28} (none)", .{"secrets"});
    } else if (!json) say("secrets (values are never shown)", .{});
    for (s.secrets.items) |sec| {
        if (!check) {
            if (json)
                secrets_json.append(a, .{ .name = sec.name, .source = sec.source, .from = sec.from, .status = "listed" }) catch oom()
            else
                say("  {s: <26} {s}   [{s}]", .{ sec.name, sec.source, sec.from });
            continue;
        }
        var f: secrets.Failure = .{};
        if (secrets.resolve(a, &.{sec}, c.env, c.envp, nimvaultOf(s), &f)) |_| {
            if (json)
                secrets_json.append(a, .{ .name = sec.name, .source = sec.source, .from = sec.from, .status = "ok" }) catch oom()
            else
                say("  {s: <26} {s}   ok", .{ sec.name, sec.source });
        } else |e| switch (e) {
            error.Unavailable => {
                if (json)
                    secrets_json.append(a, .{ .name = sec.name, .source = sec.source, .from = sec.from, .status = "failed", .detail = f.message }) catch oom()
                else
                    say("  {s: <26} {s}   FAILED: {s}", .{ sec.name, sec.source, f.message });
                failed = true;
            },
            error.OutOfMemory => oom(),
        }
    }
    // Every other command stops on a project directory it cannot use; config
    // shows the settings first, so the profile that names it can be read.
    if (s.project.value) |dir| {
        if (!projectUsable(c, dir) and check) failed = true;
    }
    if (json) {
        jsonout.emit(a, ConfigReport{
            .profile = profile,
            .check = check,
            .settings = settings.items,
            .secrets = secrets_json.items,
            .check_failed = failed,
        });
    }
    return if (failed) 1 else 0;
}

fn nimvaultOf(s: config.Settings) secrets.Nimvault {
    return .{ .program = s.nimvault_program.value, .vault = s.nimvault_vault.value };
}

/// The settings in force as EB_LOCAL_* lines, empty ones included, so the
/// same configuration can travel in the environment of a job, a container or
/// CI. Storage and build.site_toolchains have no variable: only the site file
/// sets them. A profile sets nothing else, so the lines hold all of the
/// profile in force and select none: in a job that still has the files, the
/// default profile would otherwise apply beneath them, and where the profile
/// is not defined, naming it would stop eb-local.
fn cmdConfigEnv(c: Ctx, s: config.Settings) u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    const line = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), name: []const u8, v: []const u8) void {
            o.appendSlice(al, str(al, "export {s}={s}\n", .{ name, q(al, v) })) catch oom();
        }
    }.f;
    out.appendSlice(a, "# eb-local configuration; storage and build.site_toolchains come only from the site file\n") catch oom();
    out.appendSlice(a, "# every setting of the profile in force is below, so no profile is selected beneath them\n") catch oom();
    line(a, &out, "EB_LOCAL_PROFILE", "");
    // The same absolute path `eb-local env` would use. A relative prefix, a
    // ~/ prefix and a symbolic link must not be re-resolved from another
    // directory, or followed onto a different tree, when the lines are sourced.
    const p = place(c, s);
    if (p.project) line(a, &out, "EB_LOCAL_PROJECT", p.prefix) else line(a, &out, "EB_LOCAL_PREFIX", p.prefix);
    line(a, &out, "EB_LOCAL_STACK_MODULE", s.stack_module.value);
    line(a, &out, "EB_LOCAL_STACK_EXTEND", s.extend_module.value);
    // Left at its default, dev.buildenv lets dev choose by compiler family;
    // exporting the default would turn that choice off.
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default")) line(a, &out, "EB_LOCAL_DEV_BUILDENV", s.dev_buildenv.value);
    for (config.families, s.buildenv_for) |f, b| if (!std.mem.eql(u8, b.from, "default"))
        line(a, &out, f.env, if (b.value.len == 0) config.no_buildenv else b.value);
    line(a, &out, "EB_LOCAL_DEV_MODULES", std.mem.join(a, " ", s.dev_modules.value) catch oom());
    line(a, &out, "EB_LOCAL_BUILD_ALLOCATION_HINT", s.allocation_hint.value);
    line(a, &out, "EB_LOCAL_CLEAN_TRASH", @tagName(s.trash.value));
    line(a, &out, "EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS", str(a, "{d}", .{s.logs_older_than_days.value}));
    line(a, &out, "EB_LOCAL_NIMVAULT_PROGRAM", s.nimvault_program.value);
    line(a, &out, "EB_LOCAL_NIMVAULT_VAULT", s.nimvault_vault.value);
    for (s.secrets.items) |sec| line(a, &out, str(a, "{s}{s}", .{ config.secret_env_prefix, sec.name }), sec.source);
    if (s.build_secrets.value) |names| line(a, &out, "EB_LOCAL_BUILD_SECRETS", std.mem.join(a, " ", names) catch oom());
    line(a, &out, "EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES", if (s.clear_foreign_prefixes.value) "true" else "false");
    line(a, &out, "EB_LOCAL_DOCTOR_CVMFS_PARALLEL", str(a, "{d}", .{s.cvmfs_parallel.value}));
    // [eessi] settings are environment for EESSI already; they travel as
    // themselves. An empty one is a profile clearing a site setting; the
    // clear has to be exported or the site value stays in the job.
    for (s.eessi.items) |e| line(a, &out, e.name, e.value);
    cli.put(1, out.items);
    return 0;
}

/// Print the resolved value(s) of one configuration key for scripts and
/// hooks; secrets print only their source, never their value. Exits 1 when
/// an optional or list key has no value, and 2 when `key` is unknown.
fn cmdConfigGet(c: Ctx, s: config.Settings, key: []const u8) u8 {
    const a = c.a;
    const p = locate(c, s);
    const scalar = struct {
        fn put(v: []const u8) u8 {
            if (v.len == 0) return 1;
            say("{s}", .{v});
            return 0;
        }
    }.put;
    const list = struct {
        fn put(items: []const []const u8) u8 {
            if (items.len == 0) return 1;
            for (items) |item| say("{s}", .{item});
            return 0;
        }
    }.put;

    if (std.mem.eql(u8, key, "profile")) {
        return if (s.profile) |pr| scalar(pr) else 1;
    } else if (std.mem.eql(u8, key, "project")) {
        return if (p.project) scalar(p.prefix) else 1;
    } else if (std.mem.eql(u8, key, "prefix")) {
        return if (!p.project) scalar(p.prefix) else 1;
    } else if (std.mem.eql(u8, key, "stack.module")) {
        return scalar(s.stack_module.value);
    } else if (std.mem.eql(u8, key, "stack.extend")) {
        return scalar(s.extend_module.value);
    } else if (std.mem.eql(u8, key, "dev.buildenv")) {
        return scalar(s.dev_buildenv.value);
    } else if (std.mem.startsWith(u8, key, "dev.buildenv_for.")) {
        const fam = key["dev.buildenv_for.".len..];
        for (config.families, s.buildenv_for) |f, b| {
            if (std.mem.eql(u8, f.name, fam)) return scalar(b.value);
        }
        die("unknown configuration key '{s}'", .{key});
    } else if (std.mem.eql(u8, key, "dev.modules")) {
        return list(s.dev_modules.value);
    } else if (std.mem.eql(u8, key, "build.allocation_hint")) {
        return scalar(s.allocation_hint.value);
    } else if (std.mem.eql(u8, key, "build.site_toolchains")) {
        return list(s.site_toolchains.value);
    } else if (std.mem.startsWith(u8, key, "build.node_types.")) {
        const name = key["build.node_types.".len..];
        if (name.len == 0) die("unknown configuration key '{s}'", .{key});
        for (nodeTypes(s)) |t| {
            if (std.mem.eql(u8, t.name, name)) return scalar(t.sbatch);
        }
        return 1;
    } else if (std.mem.eql(u8, key, "build.secrets")) {
        if (s.build_secrets.value) |names| return list(names);
        if (s.secrets.items.len == 0) return 1;
        for (s.secrets.items) |sec| say("{s}", .{sec.name});
        return 0;
    } else if (std.mem.eql(u8, key, "build.clear_foreign_prefixes")) {
        return scalar(if (s.clear_foreign_prefixes.value) "true" else "false");
    } else if (std.mem.eql(u8, key, "doctor.approved_prefixes")) {
        return list(s.approved_prefixes.value);
    } else if (std.mem.eql(u8, key, "doctor.cvmfs_parallel")) {
        return scalar(str(a, "{d}", .{s.cvmfs_parallel.value}));
    } else if (std.mem.eql(u8, key, "doctor.mpi_transports")) {
        return list(s.mpi_transports.value);
    } else if (std.mem.eql(u8, key, "clean.trash")) {
        return scalar(@tagName(s.trash.value));
    } else if (std.mem.eql(u8, key, "clean.logs_older_than_days")) {
        return scalar(str(a, "{d}", .{s.logs_older_than_days.value}));
    } else if (std.mem.eql(u8, key, "nimvault.program")) {
        return scalar(s.nimvault_program.value);
    } else if (std.mem.eql(u8, key, "nimvault.vault")) {
        return scalar(s.nimvault_vault.value);
    } else if (std.mem.eql(u8, key, "storage.node_local_root")) {
        return scalar(s.node_local_root.value);
    } else if (std.mem.eql(u8, key, "storage.node_local_mount")) {
        return scalar(s.node_local_mount.value);
    } else if (std.mem.eql(u8, key, "storage.node_local_fstype")) {
        return scalar(s.node_local_fstype.value);
    } else if (std.mem.eql(u8, key, "storage.shared_scratch")) {
        return list(s.shared_scratch.value);
    } else if (std.mem.startsWith(u8, key, "eessi.")) {
        const name = key["eessi.".len..];
        if (name.len == 0) die("unknown configuration key '{s}'", .{key});
        for (s.eessi.items) |v| {
            if (std.mem.eql(u8, v.name, name)) return scalar(v.value);
        }
        return 1;
    } else if (std.mem.startsWith(u8, key, "secrets.")) {
        const name = key["secrets.".len..];
        if (name.len == 0) die("unknown configuration key '{s}'", .{key});
        for (s.secrets.items) |sec| {
            if (std.mem.eql(u8, sec.name, name)) return scalar(sec.source);
        }
        return 1;
    }
    die("unknown configuration key '{s}'", .{key});
}

const SiteTemplateJson = struct { name: []const u8, placeholders: []const []const u8 };
const SiteListReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "site_list",
    templates: []const SiteTemplateJson,
};

const SiteOpts = struct {
    words: std.ArrayList([]const u8) = .empty,
    sets: std.ArrayList(sites.Set) = .empty,
    to: ?[]const u8 = null,
    force: bool = false,
    json: bool = false,
};

/// The template `eb-local site` renders: one built in, or a site's own
/// template file, named with a slash so that it is never taken for a
/// built-in name. The file is read as a configuration file is.
fn siteTemplate(c: Ctx, name: []const u8) sites.Template {
    if (std.mem.indexOfScalar(u8, name, '/') == null)
        return sites.find(name) orelse die("no site template '{s}' (eb-local site list shows them; a template file is named with a slash, as ./{s})", .{ name, name });
    const opened = openConfig(name);
    defer sys.close(opened.fd);
    const text = fsx.readAll(c.a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ name, storage.describeError(e) });
    return .{ .name = name, .text = text };
}

fn checkSiteConfig(a: Allocator, path: []const u8, text: []const u8) void {
    var empty = std.process.Environ.Map.init(a);
    var cd: config.Diagnostic = .{};
    _ = config.load(a, &.{.{ .path = path, .text = text, .layer = .site }}, &empty, .{}, &cd) catch |e| switch (e) {
        error.Invalid => die("{s}", .{cd.message}),
        error.OutOfMemory => oom(),
    };
}

fn cmdSite(c: Ctx, o: SiteOpts) u8 {
    const a = c.a;
    const w = o.words.items;
    const action = if (w.len > 0) w[0] else "list";
    if (std.mem.eql(u8, action, "list")) {
        if (w.len > 1 or o.sets.items.len > 0 or o.to != null or o.force) die("site list takes nothing else", .{});
        if (o.json) {
            var templates: std.ArrayList(SiteTemplateJson) = .empty;
            for (sites.all) |t| {
                const names = sites.placeholders(a, t.text) catch oom();
                templates.append(a, .{ .name = t.name, .placeholders = names }) catch oom();
            }
            jsonout.emit(a, SiteListReport{ .templates = templates.items });
            return 0;
        }
        for (sites.all) |t| {
            const names = sites.placeholders(a, t.text) catch oom();
            say("{s: <12} placeholders: {s}", .{ t.name, if (names.len == 0) "none" else std.mem.join(a, ", ", names) catch oom() });
        }
        return 0;
    }
    if (std.mem.eql(u8, action, "check")) {
        if (w.len != 2) die("site check takes one configuration file", .{});
        if (o.sets.items.len > 0 or o.to != null or o.force)
            die("site check takes only a configuration file", .{});
        const path = w[1];
        const opened = openConfig(path);
        defer sys.close(opened.fd);
        const raw = fsx.readAll(a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ path, storage.describeError(e) });
        const text = if (std.mem.endsWith(u8, path, ".toml")) raw else blk: {
            var ld: config.Diagnostic = .{};
            break :blk config.legacyToToml(a, raw, &ld) catch |e| switch (e) {
                error.Invalid => die("{s}: {s}", .{ path, ld.message }),
                error.OutOfMemory => oom(),
            };
        };
        checkSiteConfig(a, path, text);
        say("site file {s} is valid", .{path});
        return 0;
    }
    const show = std.mem.eql(u8, action, "show");
    if (!show and !std.mem.eql(u8, action, "install")) die("site takes list, show NAME or install NAME (or check FILE); got '{s}'", .{action});
    if (w.len != 2) die("site {s} takes one template, a name (eb-local site list shows them) or a file", .{action});
    if (show and (o.to != null or o.force)) die("site show prints the file; --to and --force are for install", .{});
    const t = siteTemplate(c, w[1]);
    var d: sites.Diagnostic = .{};
    const text = sites.render(a, t, o.sets.items, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
    const target = o.to orelse std.fs.path.join(a, &.{ selfDir(a), "config.toml" }) catch oom();
    // The file must load as the site file it is about to become. A refusal
    // names the template's line, which is the rendered file's: no value
    // holds a newline, and the target is not written yet.
    const label = std.fmt.allocPrint(a, "template {s}", .{t.name}) catch oom();
    checkSiteConfig(a, label, text);
    if (show) {
        cli.put(1, text);
        return 0;
    }
    if (fsx.statAt(fsx.cwd, target, false)) |st| {
        if (st.isDir()) {
            const clean = std.mem.trimEnd(u8, target, "/");
            die("{s} is a directory; pass a file path such as {s}/config.toml", .{ target, if (clean.len > 0) clean else "" });
        }
        if (st.isLink()) die("{s} is a symbolic link; pass a regular file path", .{target});
    } else |_| {}
    if (exists(target) and !o.force) die("{s} exists; --force replaces it", .{target});
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    common.atomic.atomicWrite(a, target, text, .{ .mode = 0o644 }, &why) catch |e|
        die("cannot write {s}: {s}", .{ target, if (why.msg.len > 0) why.msg else storage.describeError(e) });
    say("wrote {s} from template {s}; eb-local config shows what it sets", .{ target, t.name });
    return 0;
}

const ProfileRow = struct { name: []const u8, layer: []const u8, path: []const u8 };
const ProfilesReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "profiles",
    profiles: []const ProfileRow,
};

fn cmdProfiles(c: Ctx, g: Global) u8 {
    const a = c.a;
    const sources = configSources(c, g);
    // Loading checks every profile in every file.
    var d: config.Diagnostic = .{};
    _ = config.load(a, sources, c.env, .{}, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
    var rows: std.ArrayList(ProfileRow) = .empty;
    var count: usize = 0;
    for (sources) |src| {
        var td: toml.Diagnostic = .{};
        const t = toml.parse(a, src.text, &td) catch continue;
        for (config.profileNames(a, t) catch oom()) |name| {
            count += 1;
            if (g.json_out)
                rows.append(a, .{ .name = name, .layer = @tagName(src.layer), .path = src.path }) catch oom()
            else
                say("{s: <20} {s} {s}", .{ name, @tagName(src.layer), src.path });
        }
    }
    if (g.json_out) {
        jsonout.emit(a, ProfilesReport{ .profiles = rows.items });
        return 0;
    }
    if (count == 0) say("no profiles are defined", .{});
    return 0;
}

// ---- running programs -----------------------------------------------------

const Run = union(enum) {
    exit: u8,
    signal: linux.SIG,
};

/// An exit code as it is. A signal is raised again, with the disposition this
/// process was started with: the default kills the process, so a shell and
/// Slurm see the signal rather than exit 128+n and carry on, and an ignored
/// signal (nohup) stays ignored.
fn stop(run: Run) u8 {
    switch (run) {
        .exit => |c| return c,
        .signal => |sig| {
            var cur: linux.Sigaction = undefined;
            _ = linux.sigaction(sig, null, &cur);
            const ignored = cur.handler.handler == linux.SIG.IGN;
            if (!ignored) {
                const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
                _ = linux.sigaction(sig, &dfl, null);
                var set = linux.sigemptyset();
                linux.sigaddset(&set, sig);
                _ = linux.sigprocmask(linux.SIG.UNBLOCK, &set, null);
                _ = linux.kill(linux.getpid(), sig);
            }
            return @intCast(@min(255, 128 + @as(u32, @backingInt(sig))));
        },
    }
}

/// The signals that stop a program run on a terminal or in a job, and that
/// eb-local passes on to the program it waits for.
const passed_on = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT };

/// The `si_code` of a signal the kernel sent itself, as the terminal does
/// for Ctrl-C to the whole foreground process group.
const si_kernel: i32 = 0x80;

/// The program being waited for, 0 for none, and the first signal of
/// `passed_on` received while a `Guard` was held. Atomics only: the handler
/// can run between any two instructions.
var waited_pid = std.atomic.Value(linux.pid_t).init(0);
var first_signal = std.atomic.Value(u32).init(0);

fn passOn(sig: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = first_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
    // From the terminal, the signal reached the program too.
    if (info.code == si_kernel) return;
    const pid = waited_pid.load(.seq_cst);
    if (pid > 0) _ = linux.kill(pid, sig);
}

/// While a guard is held, a signal of `passed_on` does not stop eb-local.
/// One another process sent, as `kill PID` does, is passed on to the program
/// eb-local waits for; one from the terminal is not, as it reached that
/// program too, which shares the foreground process group. The first is
/// remembered, so that the caller can finish with what the program left
/// behind, release the guard and raise it again with `stop`.
const Guard = struct {
    old: [passed_on.len]linux.Sigaction,

    fn hold() Guard {
        var g: Guard = .{ .old = undefined };
        var during = linux.sigemptyset();
        for (passed_on) |sig| linux.sigaddset(&during, sig);
        const act: linux.Sigaction = .{ .handler = .{ .sigaction = passOn }, .mask = during, .flags = linux.SA.SIGINFO | linux.SA.RESTART };
        first_signal.store(0, .seq_cst);
        for (passed_on, 0..) |sig, i| {
            _ = linux.sigaction(sig, null, &g.old[i]);
            // One ignored, as nohup ignores SIGHUP, stays ignored, here and
            // in the program.
            if (g.old[i].handler.handler != linux.SIG.IGN) _ = linux.sigaction(sig, &act, null);
        }
        return g;
    }

    fn release(g: *const Guard) void {
        for (passed_on, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
    }

    fn received(_: *const Guard) ?linux.SIG {
        const v = first_signal.load(.seq_cst);
        return if (v == 0) null else @fromBackingInt(@intCast(v));
    }

    /// Run a program on this terminal and wait for it to exit.
    fn run(g: *const Guard, a: Allocator, argv: []const []const u8, envp: proc.Envp) Run {
        const zargv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch oom();
        for (argv, 0..) |x, i| zargv[i] = (a.dupeSentinel(u8, x, 0) catch oom()).ptr;
        // Blocked until this process knows the child, and the child has the
        // dispositions this process started with (nohup's, an ignored
        // SIGINT), so that the handler never runs in the child.
        var block = linux.sigemptyset();
        for (passed_on) |sig| linux.sigaddset(&block, sig);
        var mask: linux.sigset_t = undefined;
        _ = linux.sigprocmask(linux.SIG.BLOCK, &block, &mask);
        if (g.received()) |sig| {
            _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
            return .{ .signal = sig };
        }
        const pid: isize = @bitCast(linux.fork());
        if (pid == 0) {
            for (passed_on, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
            _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
            const rc = linux.execve(zargv[0].?, zargv.ptr, envp);
            cli.err("eb-local: cannot run {s} ({s})\n", .{ argv[0], sys.describeErrno(linux.errno(rc)) });
            linux.exit_group(127);
        }
        if (pid > 0) waited_pid.store(@intCast(pid), .seq_cst);
        _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
        if (pid < 0) die("cannot start {s}", .{argv[0]});
        // Waited for without reaping, so that its pid cannot be reused
        // before the handler forgets it.
        var info: linux.siginfo_t = undefined;
        while (true) {
            const rc = linux.waitid(.PID, @intCast(pid), &info, linux.W.EXITED | linux.W.NOWAIT, null);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => break,
            }
        }
        waited_pid.store(0, .seq_cst);
        var raw: i32 = 0;
        while (true) {
            const rc = linux.wait4(@intCast(pid), &raw, 0, null);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return .{ .exit = 1 },
            }
        }
        const status: u32 = @bitCast(raw);
        if (linux.W.IFEXITED(status)) return .{ .exit = linux.W.EXITSTATUS(status) };
        if (linux.W.IFSIGNALED(status)) return .{ .signal = linux.W.TERMSIG(status) };
        return .{ .exit = 1 };
    }
};

/// Run a program on this terminal and wait for it, holding a `Guard`. A
/// signal eb-local received is the result, whatever the program did with
/// it, so that the caller cleans up and raises it again.
fn runAttached(a: Allocator, argv: []const []const u8, envp: proc.Envp) Run {
    const guard = Guard.hold();
    defer guard.release();
    const ran = guard.run(a, argv, envp);
    return if (guard.received()) |sig| .{ .signal = sig } else ran;
}

fn envpOf(a: Allocator, map: *const std.process.Environ.Map) proc.Envp {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| {
        const line = std.fmt.allocPrintSentinel(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0) catch oom();
        list.append(a, line.ptr) catch oom();
    }
    list.append(a, null) catch oom();
    return @ptrCast(list.items.ptr);
}

/// The line for eessi-arch-guard, whose target builds, env and dev load
/// EESSI for. Inside a job with EESSI loaded the guard is asked as a build
/// asks it, strictly, with a private directory that is removed after.
fn noteGuard(c: Ctx, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) void {
    const a = c.a;
    const guard = (proc.which(a, "eessi-arch-guard", c.env.get("PATH") orelse "") catch null) orelse
        return note(a, out, json_lines, "info", "eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI detects", .{});
    if (std.mem.eql(u8, c.env.get("EESSI_ARCH_GUARD") orelse "", "0"))
        return note(a, out, json_lines, "info", "eessi-arch-guard is on PATH, and EESSI_ARCH_GUARD=0 turns it off", .{});
    const loaded = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR")) orelse "";
    if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null or loaded.len == 0)
        return note(a, out, json_lines, "info", "eessi-arch-guard is on PATH; builds, env and dev load EESSI for the target it selects, which doctor shows inside a job with EESSI loaded", .{});
    const tmp = nonEmpty(c.env.get("TMPDIR")) orelse "/tmp";
    const base = if (fsx.statAt(fsx.cwd, tmp, true)) |st| (if (st.isDir()) tmp else "/tmp") else |_| "/tmp";
    const dir = storage.makeWorkspace(a, base) catch
        return note(a, out, json_lines, "warn", "eessi-arch-guard was not asked: doctor could not make a private directory in {s}", .{base});
    defer fsx.deleteTree(a, fsx.cwd, dir) catch {};
    var env = c.env.clone(a) catch oom();
    env.put("EESSI_ARCH_GUARD_WORKDIR", dir) catch oom();
    const r = proc.run(a, guard, &.{ guard, "--strict", "--shell" }, envpOf(a, &env), .{ .stdout_limit = 1 << 20, .stderr_limit = 64 << 10, .timeout_ms = 120_000 }) catch |e|
        return note(a, out, json_lines, "warn", "eessi-arch-guard could not be run: {s}", .{@errorName(e)});
    if (r.term.code() != 0) {
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, r.stderr, " \n"), '\n');
        const why = lines.first();
        return note(a, out, json_lines, "warn", "eessi-arch-guard cannot select a target here (exit {d}{s}{s}); builds stop when it cannot, and EESSI_ARCH_GUARD=0 turns it off", .{ r.term.code(), if (why.len > 0) ": " else "", why });
    }
    const chosen = shellExport(a, r.stdout, "EESSI_SOFTWARE_SUBDIR") orelse loaded;
    if (std.mem.eql(u8, chosen, loaded)) {
        note(a, out, json_lines, "ok  ", "eessi-arch-guard selects {s}, the target EESSI is loaded for", .{chosen});
    } else note(a, out, json_lines, "ok  ", "eessi-arch-guard selects {s} here, not {s}, which EESSI is loaded for; builds, env and dev use {s}", .{ chosen, loaded, chosen });
}

/// The value `export NAME=VALUE` gives NAME in the output of
/// eessi-arch-guard --shell, without the quotes Python's shlex.quote adds.
fn shellExport(a: Allocator, text: []const u8, name: []const u8) ?[]const u8 {
    const head = str(a, "export {s}=", .{name});
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, head)) continue;
        const v = line[head.len..];
        if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'')
            return std.mem.replaceOwned(u8, a, v[1 .. v.len - 1], "'\"'\"'", "'") catch oom();
        return v;
    }
    return null;
}

test "the value eessi-arch-guard --shell gives a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "export EESSI_ARCH_GUARD_RELOADED='x86_64/amd/zen4->x86_64/amd/zen2'\nexport EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen2\nunset EESSI_ARCHDETECT_OPTIONS\n";
    try std.testing.expectEqualStrings("x86_64/amd/zen2", shellExport(a, text, "EESSI_SOFTWARE_SUBDIR").?);
    try std.testing.expectEqualStrings("x86_64/amd/zen4->x86_64/amd/zen2", shellExport(a, text, "EESSI_ARCH_GUARD_RELOADED").?);
    try std.testing.expectEqualStrings("it's", shellExport(a, "export X='it'\"'\"'s'\n", "X").?);
    try std.testing.expect(shellExport(a, text, "EESSI_ARCHDETECT_OPTIONS") == null);
    try std.testing.expect(shellExport(a, text, "EESSI_SOFTWARE") == null);
}

/// Your user name, for %u in storage.node_local_mount. `undone` is what the
/// command does not do when there is none.
fn userName(c: Ctx, s: config.Settings, undone: []const u8) []const u8 {
    // A static binary has no NSS; id(1) asks the system's.
    const id = (proc.which(c.a, "id", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/usr/bin/id";
    const failed = "cannot tell your user name: {s} -un {s}; {s}.\n" ++
        "  eb-local puts it for %u in storage.node_local_mount, {s} [{s}]; run eb-local where id -un prints your user name.";
    const r = proc.run(c.a, id, &.{ id, "-un" }, c.envp, .{ .stdout_limit = 4096, .timeout_ms = 10_000 }) catch |e|
        die(failed, .{ id, str(c.a, "could not run ({s})", .{@errorName(e)}), undone, s.node_local_mount.value, s.node_local_mount.from });
    if (r.term.code() != 0) die(failed, .{ id, str(c.a, "failed with status {d}", .{r.term.code()}), undone, s.node_local_mount.value, s.node_local_mount.from });
    return std.mem.trim(u8, r.stdout, " \n");
}

fn mountinfoText(c: Ctx) []const u8 {
    var path: []const u8 = "/proc/self/mountinfo";
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_MOUNTINFO"))) |p| path = p;
    }
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch |e| die("cannot read {s} ({s})", .{ path, storage.describeError(e) });
    defer sys.close(fd);
    return fsx.readAll(c.a, fd, 8 << 20) catch |e| die("cannot read {s} ({s})", .{ path, storage.describeError(e) });
}

/// The caller's uid. Only the test artifact lets EB_LOCAL_TEST_UID stand in,
/// so that a test can make its own directory look like another user's.
fn callerUid(c: Ctx) linux.uid_t {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_UID"))) |v| return std.fmt.parseInt(linux.uid_t, v, 10) catch linux.getuid();
    }
    return linux.getuid();
}

fn nodeLocal(s: config.Settings) storage.NodeLocal {
    return .{
        .root = s.node_local_root.value,
        .root_from = s.node_local_root.from,
        .mount = s.node_local_mount.value,
        .mount_from = s.node_local_mount.from,
        .fstype = s.node_local_fstype.value,
        .fstype_from = s.node_local_fstype.from,
    };
}

/// The allocation's node-local mount. A refusal says what was refused and
/// why, then what to change; `undone` is what the command then did not do.
fn checkedJobRoot(c: Ctx, s: config.Settings, undone: []const u8) []const u8 {
    if (s.node_local_root.value.len == 0)
        die("no site file sets storage.node_local_root, the directory that holds each job's node-local mount; {s}.\n" ++
            "  Set it in the site file, which eb-local site install slurm --set node_local_root=DIR writes, or name a site file " ++
            "that root or this program's owner owns with --config FILE or EB_LOCAL_CONFIG=FILE. eb-local eb needs no site file.", .{undone});
    var r: storage.Refusal = .{};
    const job_id = c.env.get("SLURM_JOB_ID") orelse "";
    const jr = storage.jobRoot(c.a, nodeLocal(s), job_id, userName(c, s, undone), mountinfoText(c), callerUid(c), &r) catch |e| switch (e) {
        error.Refused => die("{s}; {s}.\n  {s}.", .{ r.message, undone, r.fix }),
        error.OutOfMemory => oom(),
    };
    return jr.path;
}

/// Where the prefix in force was set, as `eb-local config` shows it.
fn prefixFrom(s: config.Settings, p: Place) []const u8 {
    return if (p.project) s.project.from else s.prefix.from;
}

/// What to change when a prefix is refused.
const prefix_fix = "set a prefix on durable storage you own with prefix in your eb-local configuration, EB_LOCAL_PREFIX, or --project DIR for a project";

/// Why a prefix is refused when it, or a tree below it, is on refused storage.
const outlive = "Installs, sources and logs must outlive the job and not be on shared scratch";

/// A tree a build writes nothing to, with the setting that names it.
const RefusedTree = struct { path: []const u8, what: []const u8 };

/// Shared scratch and the node-local root, as configured and, when
/// `resolved`, as the kernel resolves them, so that an alias (a symbolic
/// link to shared scratch) is refused as the tree itself is.
fn refusedTrees(c: Ctx, s: config.Settings, resolved: bool) []const RefusedTree {
    const a = c.a;
    const scratch = str(a, "shared scratch in storage.shared_scratch [{s}]", .{s.shared_scratch.from});
    const local = str(a, "node-local storage below storage.node_local_root [{s}]", .{s.node_local_root.from});
    var configured: std.ArrayList(RefusedTree) = .empty;
    for (s.shared_scratch.value) |r| configured.append(a, .{ .path = r, .what = scratch }) catch oom();
    if (s.node_local_root.value.len > 0) configured.append(a, .{ .path = s.node_local_root.value, .what = local }) catch oom();
    if (!resolved) return configured.items;
    var out: std.ArrayList(RefusedTree) = .empty;
    for (configured.items) |t| {
        out.append(a, t) catch oom();
        out.append(a, .{ .path = storage.canonical(a, t.path, c.cwd) catch oom(), .what = t.what }) catch oom();
    }
    return out.items;
}

const Durable = struct {
    sources: []const u8,
    logs: []const u8,
};

/// Sources and logs live beside the installation, and must stay there.
/// `undone` is what the command does not do when one leads elsewhere.
fn durableDirs(c: Ctx, prefix: []const u8, undone: []const u8) Durable {
    const root = std.fs.path.join(c.a, &.{ prefix, ".eb-local" }) catch oom();
    const d: Durable = .{
        .sources = std.fs.path.join(c.a, &.{ root, "sources" }) catch oom(),
        .logs = std.fs.path.join(c.a, &.{ root, "logs" }) catch oom(),
    };
    for ([_][]const u8{ d.sources, d.logs }) |p| {
        const resolved = storage.canonical(c.a, p, c.cwd) catch oom();
        if (!storage.under(resolved, prefix) or std.mem.eql(u8, resolved, prefix))
            die("{s} leads to {s}, not to a directory inside the install prefix {s}; {s}.\n" ++
                "  Sources and logs stay in the durable prefix, beside the installs: replace the symbolic link in {s} with a directory, or " ++ prefix_fix ++ ".", .{ p, resolved, prefix, undone, p });
    }
    return d;
}

fn acquirePrefixLock(c: Ctx, prefix: []const u8) ?sys.fd_t {
    const a = c.a;
    var err_msg: []const u8 = "";
    const timeout_ms = storage.lockTimeoutMs(c.env, &err_msg) orelse die("{s}", .{err_msg});
    const dir = std.fs.path.join(a, &.{ prefix, ".eb-local" }) catch oom();
    common.atomic.makedirs(dir) catch |e| die("cannot create {s} ({s})", .{ dir, sys.describe(e) });
    const lock_path = std.fs.path.join(a, &.{ dir, ".lock" }) catch oom();
    return switch (storage.acquireBoundedLock(a, lock_path, timeout_ms, true, &err_msg)) {
        .held => |fd| fd,
        .unlocked => null,
        .failed => die("{s}", .{err_msg}),
    };
}

/// The stop when the checked node-local mount takes no workspace.
fn workspaceFailed(a: Allocator, job_root: []const u8, e: anyerror) noreturn {
    if (e == error.OutOfMemory) oom();
    die("cannot make a build workspace in the node-local mount {s} ({s}); nothing was built.\n" ++
        "  The mount passed eb-local's checks, so it may be full or have changed since; df {s} shows its free space.", .{ job_root, storage.describeError(e), q(a, job_root) });
}

// ---- clean ----------------------------------------------------------------

const CleanOpts = struct {
    logs: bool = true,
    logs_days: ?u32 = null,
    sources: bool = false,
    workspaces: bool = false,
    dry_run: bool = false,
    delete: bool = false,
};

const Target = struct { path: []const u8, dir: bool = false };

const Collect = struct {
    c: Ctx,
    out: std.ArrayList(Target) = .empty,

    /// The directory `path` to collect from, never reached through a
    /// symbolic link; null when there is none.
    fn top(path: []const u8) ?fsx.Stat {
        const st = fsx.statAt(fsx.cwd, path, false) catch return null;
        if (st.isLink()) die("{s} is reached through a symbolic link; clean leaves it alone.", .{path});
        if (!st.isDir()) return null;
        var buf: [sys.path_max]u8 = undefined;
        const real = fsx.realpath(fsx.cwd, path, &buf) catch return null;
        if (!std.mem.eql(u8, real, path)) die("{s} is reached through a symbolic link; clean leaves it alone.", .{path});
        return st;
    }

    /// Regular files below `path`, on its file system, never through a
    /// symbolic link.
    fn files(self: *Collect, path: []const u8) void {
        const st = top(path) orelse return;
        self.walk(path, st.dev, 0);
    }

    fn walk(self: *Collect, path: []const u8, dev: u64, depth: usize) void {
        if (depth > 16) return;
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(self.c.a, fd) catch return;
        while (it.next() catch null) |e| {
            const st = fsx.statAt(fd, e.name, false) catch continue;
            if (st.dev != dev) continue;
            const child = std.fs.path.join(self.c.a, &.{ path, e.name }) catch oom();
            if (st.isDir()) {
                self.walk(child, dev, depth + 1);
            } else if (st.isReg()) {
                self.out.append(self.c.a, .{ .path = child }) catch oom();
            }
        }
    }

    /// The files and directories in `path` with nothing in them modified
    /// since `cutoff`, each whole: EasyBuild copies a build's easyconfig,
    /// easyblocks and hooks into reprod_<time>_<pid>/ with their own older
    /// times, so a file's age is not its build's. A directory holding
    /// another file system, or one clean cannot read through, stays.
    fn aged(self: *Collect, path: []const u8, cutoff: i64) void {
        const st = top(path) orelse return;
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(self.c.a, fd) catch return;
        while (it.next() catch null) |e| {
            const est = fsx.statAt(fd, e.name, false) catch continue;
            if (est.dev != st.dev or !(est.isDir() or est.isReg())) continue;
            const child = std.fs.path.join(self.c.a, &.{ path, e.name }) catch oom();
            var newest = est.mtime.sec;
            if (est.isDir() and !newestBelow(self.c, child, st.dev, &newest, 0)) continue;
            if (newest >= cutoff) continue;
            self.out.append(self.c.a, .{ .path = child, .dir = est.isDir() }) catch oom();
        }
    }
};

/// Raises `newest` to the latest modification below `path`; false when
/// something there is on another file system or cannot be read.
fn newestBelow(c: Ctx, path: []const u8, dev: u64, newest: *i64, depth: usize) bool {
    if (depth > 16) return false;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return false;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return false;
    while (it.next() catch return false) |e| {
        const st = fsx.statAt(fd, e.name, false) catch return false;
        if (st.dev != dev) return false;
        newest.* = @max(newest.*, st.mtime.sec);
        if (st.isDir() and !newestBelow(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), dev, newest, depth + 1)) return false;
    }
    return true;
}

fn removeEmptyDirs(c: Ctx, path: []const u8, dev: u64, depth: usize) void {
    if (depth > 16) return;
    const here = fsx.statAt(fsx.cwd, path, false) catch return;
    if (here.dev != dev or !here.isDir()) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (st.dev != dev or !st.isDir()) continue;
        removeEmptyDirs(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), dev, depth + 1);
        sys.unlinkat(fd, e.name, linux.AT.REMOVEDIR) catch {};
    }
}

const CleanItemJson = struct { path: []const u8, kind: []const u8 };
const CleanReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "clean",
    prefix: []const u8,
    dry_run: bool,
    action: []const u8,
    items: []const CleanItemJson,
    workspaces: []const []const u8,
    removed_items: usize,
    removed_workspaces: usize,
};

fn emitCleanJson(a: Allocator, prefix: []const u8, dry_run: bool, action: []const u8, targets: []const Target, spaces: []const []const u8, removed_items: usize, removed_workspaces: usize) void {
    var items: std.ArrayList(CleanItemJson) = .empty;
    for (targets) |t| items.append(a, .{ .path = t.path, .kind = if (t.dir) "dir" else "file" }) catch oom();
    jsonout.emit(a, CleanReport{
        .prefix = prefix,
        .dry_run = dry_run,
        .action = action,
        .items = items.items,
        .workspaces = spaces,
        .removed_items = removed_items,
        .removed_workspaces = removed_workspaces,
    });
}

fn cmdClean(c: Ctx, s: config.Settings, o: CleanOpts, json: bool) u8 {
    const a = c.a;
    var job_root: ?[]const u8 = null;
    if (o.workspaces) {
        if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null)
            die("clean --workspaces works only inside the Slurm job that made the workspaces, and SLURM_JOB_ID is unset or empty; nothing was removed.\n" ++
                "  A build workspace is in its job's node-local mount, which goes when the job ends; run eb-local clean --workspaces inside that job, " ++
                "in its batch script or with srun --jobid=JOBID --overlap.", .{});
        job_root = checkedJobRoot(c, s, "nothing was removed");
    }
    const p = place(c, s);
    const d = durableDirs(c, p.prefix, "nothing was removed");
    var trash = s.trash.value;
    const rtrash = proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null;
    switch (trash) {
        .auto => trash = if (rtrash != null) .rtrash else .none,
        .rtrash => if (rtrash == null) die("clean.trash is rtrash, but rtrash is not on PATH.", .{}),
        .none => {},
    }
    var prefix_lock: ?sys.fd_t = null;
    defer storage.releaseLock(&prefix_lock);
    if (!o.dry_run and (o.logs or o.sources)) {
        const eb_local_dir = std.fs.path.join(a, &.{ p.prefix, ".eb-local" }) catch oom();
        if (fsx.statAt(fsx.cwd, eb_local_dir, false)) |st| {
            if (st.isDir()) prefix_lock = acquirePrefixLock(c, p.prefix);
        } else |_| {}
    }
    // find -mtime +N: more than N whole days old.
    const days: i64 = o.logs_days orelse s.logs_older_than_days.value;
    const now: i64 = nowSecs();
    var collect: Collect = .{ .c = c };
    if (o.logs) collect.aged(d.logs, now - (days + 1) * 86400 + 1);
    if (o.sources) collect.files(d.sources);
    var spaces: std.ArrayList([]const u8) = .empty;
    if (job_root) |jr| {
        const fd = fsx.openDir(fsx.cwd, jr, false) catch die("cannot read {s}", .{jr});
        defer sys.close(fd);
        var it = fsx.DirIter.init(a, fd) catch die("cannot read {s}", .{jr});
        while (it.next() catch null) |e| {
            const full = std.fs.path.join(a, &.{ jr, e.name }) catch oom();
            if (storage.ownWorkspace(jr, full, callerUid(c))) {
                const ws_lock = std.fs.path.join(a, &.{ full, ".eb-local.lock" }) catch oom();
                if (storage.tryLockFree(ws_lock)) spaces.append(a, full) catch oom();
            }
        }
    }
    const targets = collect.out.items;
    if (targets.len == 0 and spaces.items.len == 0) {
        if (json) {
            emitCleanJson(a, p.prefix, o.dry_run, "nothing", targets, spaces.items, 0, 0);
        } else {
            say("eb-local: nothing to clean in {s}", .{p.prefix});
        }
        return 0;
    }
    if (!json) {
        for (targets) |t| say("  {s}{s}", .{ t.path, if (t.dir) "/" else "" });
        for (spaces.items) |w| say("  {s}/ (build workspace)", .{w});
    }
    if (o.dry_run) {
        if (json) {
            emitCleanJson(a, p.prefix, true, "dry-run", targets, spaces.items, 0, 0);
        } else {
            say("eb-local: dry run, nothing removed ({d} item(s), {d} workspace(s))", .{ targets.len, spaces.items.len });
        }
        return 0;
    }
    if (targets.len > 0 and trash != .rtrash and !o.delete) {
        notTrashed(s);
        if (json) emitCleanJson(a, p.prefix, false, "refused", targets, spaces.items, 0, 0);
        return 1;
    }
    // Build workspaces are node-local scratch the scheduler removes anyway;
    // they are deleted, not trashed.
    var removed_ws: usize = 0;
    for (spaces.items) |w| {
        if (storage.removeTree(a, w)) |_| {
            removed_ws += 1;
        } else |e| warn("cannot remove {s} ({s})", .{ w, @errorName(e) });
    }
    if (!json and spaces.items.len > 0) say("eb-local: removed {d} build workspace(s)", .{removed_ws});
    var removed_items: usize = 0;
    var action: []const u8 = "workspaces-only";
    if (targets.len > 0) {
        if (trash == .rtrash) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(a, &.{ rtrash.?, "put" }) catch oom();
            for (targets) |t| if (t.dir) {
                argv.append(a, "-r") catch oom();
                break;
            };
            argv.append(a, "--") catch oom();
            for (targets) |t| argv.append(a, t.path) catch oom();
            const run = runAttached(a, argv.items, c.envp);
            switch (run) {
                .exit => |rc| if (rc != 0) die("rtrash put exited {d}", .{rc}),
                .signal => return stop(run),
            }
            removed_items = targets.len;
            action = "trashed";
            if (!json) say("eb-local: moved {d} item(s) to the trash (rtrash list, rtrash restore)", .{targets.len});
        } else {
            for (targets) |t| {
                if (t.dir) {
                    if (storage.removeTree(a, t.path)) |_| {
                        removed_items += 1;
                    } else |e| warn("cannot remove {s} ({s})", .{ t.path, @errorName(e) });
                } else {
                    if (sys.unlinkat(fsx.cwd, t.path, 0)) |_| {
                        removed_items += 1;
                    } else |e| warn("cannot remove {s} ({s})", .{ t.path, @errorName(e) });
                }
            }
            action = "deleted";
            if (!json) say("eb-local: deleted {d} item(s)", .{removed_items});
        }
        for ([_][]const u8{ d.logs, d.sources }) |dir| {
            const st = fsx.statAt(fsx.cwd, dir, false) catch continue;
            removeEmptyDirs(c, dir, st.dev, 0);
        }
    }
    if (json) emitCleanJson(a, p.prefix, false, action, targets, spaces.items, removed_items, removed_ws);
    if (removed_ws < spaces.items.len or removed_items < targets.len) return 1;
    return 0;
}

// ---- build ----------------------------------------------------------------

/// The part of a build that needs Lmod runs in bash. The stack, extension,
/// install variable, prefix and mode come as arguments and the easyconfig
/// arguments after them, so nothing a user typed is part of the script.
const test_prelude =
    \\if [ -n "${EB_LOCAL_TEST_PRELUDE:-}" ]; then
    \\    # The test artifact's stand-in for BASH_ENV. A release build has no
    \\    # such seam: bash would run BASH_ENV before this script.
    \\    source "$EB_LOCAL_TEST_PRELUDE"
    \\    unset EB_LOCAL_TEST_PRELUDE
    \\fi
    \\
;

/// What a shell without a module command sources for one, in this order:
/// the host's Lmod, then EESSI's own, from the init `eb-local eb` sources,
/// for a host whose only Lmod is EESSI's. `lmodInits` names the same files.
const lmod_init =
    \\if ! type module >/dev/null 2>&1; then
    \\    for eb_local_init in "${LMOD_PKG:-/usr/share/lmod/lmod}/init/bash" /etc/profile.d/lmod.sh \
    \\        "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/versions/${EESSI_VERSION:-2026.06}/init/lmod/bash"; do
    \\        [ -f "$eb_local_init" ] && [ -r "$eb_local_init" ] && { . "$eb_local_init" >/dev/null; break; }
    \\    done
    \\    unset eb_local_init
    \\fi
    \\
;

/// The files `lmod_init` tries, in its order.
fn lmodInits(a: Allocator, env: *const std.process.Environ.Map) [3][]const u8 {
    const pkg = nonEmpty(env.get("LMOD_PKG")) orelse "/usr/share/lmod/lmod";
    return .{
        std.fs.path.join(a, &.{ pkg, "init", "bash" }) catch oom(),
        "/etc/profile.d/lmod.sh",
        extend.initPath(a, env) catch oom(),
    };
}

/// Whether a directory on `modulepath` holds the module `name`: a Lua file,
/// a Tcl file, or for a name without a version, a directory of versions.
fn onModulePath(a: Allocator, modulepath: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, modulepath, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const file = std.fs.path.join(a, &.{ dir, name }) catch oom();
        const lua = std.fmt.allocPrint(a, "{s}.lua", .{file}) catch oom();
        for ([_][]const u8{ lua, file }) |path| if (fsx.statAt(fsx.cwd, path, true)) |_| return true else |_| {};
    }
    return false;
}

fn readable(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, true) catch return false;
    if (!st.isReg()) return false;
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return false;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.R_OK, 0)) == .SUCCESS;
}

const build_script = "set -eo pipefail\n" ++ (if (build_options.test_ops) test_prelude else "") ++
    \\stack=$1 extend=$2 install_var=$3 prefix=$4 mode=$5
    \\shift 5
    \\keep=(WORKING_DIR TMPDIR TMP TEMP EASYBUILD_BUILDPATH EASYBUILD_TMPDIR XDG_CACHE_HOME CARGO_HOME EASYBUILD_SOURCEPATH EASYBUILD_TMP_LOGDIR)
    \\declare -A saved
    \\for v in "${keep[@]}"; do saved[$v]=${!v}; done
    \\restore() { for v in "${keep[@]}"; do export "$v=${saved[$v]}"; done; }
    \\# A load that works fills stderr with the modules' own messages; one that
    \\# fails leaves Lmod's reason there, so only a failed load shows it.
    \\load() {
    \\    local err="${saved[TMPDIR]}/module-load.err" line
    \\    module load "$1" >/dev/null 2>"$err" && return
    \\    echo "eb-local: could not load $1:" >&2
    \\    while IFS= read -r line; do echo "${line:+  $line}" >&2; done < "$err"
    \\    exit 1
    \\}
    \\
++ lmod_init ++
    \\type module >/dev/null 2>&1 || {
    \\    echo "eb-local: no module command found; none of ${LMOD_PKG:-/usr/share/lmod/lmod}/init/bash, /etc/profile.d/lmod.sh or ${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/versions/${EESSI_VERSION:-2026.06}/init/lmod/bash defined one" >&2
    \\    exit 1
    \\}
    \\# EESSI-extend reads the variables when it loads, so it is loaded fresh.
    \\module unload "$extend" >/dev/null 2>&1 || true
    \\unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL
    \\unset EESSI_SITE_SOFTWARE_PREFIX
    \\unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK
    \\unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX
    \\restore
    \\export "$install_var=$prefix"
    \\# Lmod finds every module of a load before it loads any; the extension
    \\# is on MODULEPATH only once the stack is loaded. The extension reads
    \\# WORKING_DIR and EASYBUILD_SOURCEPATH as it loads, so whatever the
    \\# stack module set, the paths go back first.
    \\load "$stack"
    \\restore
    \\# Tasks run with the CPU target eessi-arch-guard selects, which can be
    \\# below the one EESSI detects: on a CPU without a flag GCC enables for the
    \\# detected target, the guard takes the next one. Where the guard is
    \\# installed, the build installs for its target, and a guard that cannot
    \\# select one stops the build. --strict restores in a private directory,
    \\# which the workspace is.
    \\if command -v eessi-arch-guard >/dev/null 2>&1; then
    \\    delta=$(EESSI_ARCH_GUARD_WORKDIR="${saved[EASYBUILD_BUILDPATH]%/build}" eessi-arch-guard --strict --shell) || {
    \\        echo "eb-local: eessi-arch-guard could not select this node's target; nothing was built" >&2
    \\        exit 1
    \\    }
    \\    eval "$delta"
    \\    restore
    \\fi
    \\load "$extend"
    \\restore
    \\# EESSI-extend chose the install path as it loaded. eb-local checked the
    \\# prefix's versions tree, lists it and cleans its logs of secrets, so an
    \\# install path anything else chose stops the build. An install variable
    \\# a load hook sets acts only on the next load.
    \\see='See "Where EESSI-extend installs": https://stackhands.github.io/eb-local/explanation/install-variables.html'
    \\for v in EESSI_USER_INSTALL EESSI_PROJECT_INSTALL EESSI_SITE_INSTALL EESSI_CVMFS_INSTALL; do
    \\    if [ "$v" = "$install_var" ]; then want=set:$prefix; else want=; fi
    \\    [ "${!v+set:${!v}}" = "$want" ] && continue
    \\    if [ -n "${!v+set}" ]; then what="set $v=${!v}"; else what="unset $v"; fi
    \\    echo "eb-local: loading $extend $what; this build still installs into $prefix, but a shell that loads EESSI-extend by hand keeps the change, and its next load installs elsewhere." >&2
    \\    echo "  A site Lmod hook that sets an install variable acts only on the next load. $see" >&2
    \\done
    \\for v in EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES; do
    \\    if [ -n "${!v+set}" ]; then
    \\        echo "eb-local: loading $extend set $v=${!v}, which would put part of the install outside $prefix/versions, the tree eb-local checked; nothing was built." >&2
    \\        echo "  A site Lmod hook or a changed EESSI-extend set it. $see" >&2
    \\        exit 2
    \\    fi
    \\done
    \\installpath=${EASYBUILD_INSTALLPATH-}
    \\if [[ $installpath != "$prefix"/versions/?* || /$installpath/ == */../* ]]; then
    \\    echo "eb-local: loading $extend set the install path to ${installpath:-nothing}, outside $prefix/versions, the tree eb-local checked; nothing was built." >&2
    \\    echo "  $install_var did not choose it: a site Lmod hook, a changed EESSI-extend, or a character such as - in EESSI_CVMFS_REPO, which EESSI-extend matches as a Lua pattern, did. $see" >&2
    \\    exit 2
    \\fi
    \\# The hooks of EESSI $EESSI_VERSION accept these toolchains besides foss and lfoss.
    \\if [ -n "${EB_LOCAL_SITE_TOOLCHAINS:-}" ]; then
    \\    [ -n "${EESSI_VERSION:-}" ] || { echo "eb-local: $stack set no EESSI_VERSION; cannot apply build.site_toolchains" >&2; exit 1; }
    \\    export "EESSI_SITE_TOP_LEVEL_TOOLCHAINS_${EESSI_VERSION//./_}=$EB_LOCAL_SITE_TOOLCHAINS"
    \\fi
    \\unset EB_LOCAL_SITE_TOOLCHAINS
    \\echo "eb-local: installing into $prefix ($mode)"
    \\echo "eb-local: target $EESSI_SOFTWARE_SUBDIR${EESSI_ACCELERATOR_TARGET:+ + $EESSI_ACCELERATOR_TARGET}, build space ${saved[EASYBUILD_BUILDPATH]%/build}"
    \\# EasyBuild keeps the umask EESSI-extend sets for the install, 077 and the
    \\# sticky bit for a user one, 002 and the setgid bit for a project.
    \\# eb replaces this shell, so the program eb-local waits for, and passes
    \\# a signal on to, is EasyBuild, which writes the logs it then cleans.
    \\exec eb "$@"
;

/// What bash would run before the script could unset it: bash runs BASH_ENV
/// first, and SHELLOPTS=xtrace prints the commands into the job log.
const shell_startup = [_][]const u8{ "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS" };

/// Host loader settings, which select libraries ahead of the toolchain's
/// RPATH.
const host_loader = [_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT" };

/// Whether `value`, an LD_PRELOAD list split on ':' or ' ', names only
/// XALT's libxalt_init.so: the usage tracker sites preload for every
/// login. A build leaves it out like any preload, without a warning.
fn onlyXalt(value: []const u8) bool {
    var seen = false;
    var it = std.mem.tokenizeAny(u8, value, ": ");
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, std.fs.path.basename(entry), "libxalt_init.")) return false;
        seen = true;
    }
    return seen;
}

/// The variables a build sets for its script: build and temporary space in
/// the workspace `work`, sources and logs beside the install.
fn buildVariables(a: Allocator, work: []const u8, d: Durable) [11][2][]const u8 {
    const tmp = std.fs.path.join(a, &.{ work, "tmp" }) catch oom();
    return .{
        .{ "WORKING_DIR", std.fs.path.join(a, &.{ work, "source-index" }) catch oom() },
        .{ "TMPDIR", tmp },
        .{ "TMP", tmp },
        .{ "TEMP", tmp },
        .{ "EASYBUILD_BUILDPATH", std.fs.path.join(a, &.{ work, "build" }) catch oom() },
        .{ "EASYBUILD_TMPDIR", tmp },
        .{ "XDG_CACHE_HOME", std.fs.path.join(a, &.{ work, "cache" }) catch oom() },
        .{ "CARGO_HOME", std.fs.path.join(a, &.{ work, "cargo" }) catch oom() },
        .{ "EASYBUILD_SOURCEPATH", d.sources },
        .{ "EASYBUILD_TMP_LOGDIR", d.logs },
        .{ "LMOD_EXACT_MATCH", "no" },
    };
}

fn buildUmask(p: Place) u32 {
    return if (p.project) 0o002 else 0o077;
}

/// The command a build runs: `build_script` in a clean bash, with the stack,
/// the extension, the install variable, the prefix and the mode as its first
/// five arguments, and eb's after them.
fn buildCommand(a: Allocator, c: Ctx, s: config.Settings, p: Place, args: []const []const u8) []const []const u8 {
    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{
        bash,                 "--noprofile",         "--norc",                                                         "-c",     build_script,                         "eb-local",
        s.stack_module.value, s.extend_module.value, if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", p.prefix, if (p.project) "project" else "user",
    }) catch oom();
    argv.appendSlice(a, args) catch oom();
    return argv.items;
}

/// What a build runs: its script, after the variables eb-local sets for it
/// and a `set --` line with its arguments, and the checks eb-local makes
/// first as comments. Nothing is created and nothing runs, so it also works
/// outside an allocation. $W stands for the workspace a build makes in the
/// allocation's node-local mount.
fn explainBuild(c: Ctx, s: config.Settings, g: Global, args: []const []const u8) u8 {
    const a = c.a;
    const p = place(c, s);
    const d = durableDirs(c, p.prefix, "a build would stop here");
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "# eb-local --explain: the script a build runs, with its environment and arguments. Nothing was created or run.\n") catch oom();
    out.print(a, "# Installs as a {s} install into {s} (prefix from {s}).\n", .{
        if (p.project) "project" else "user", p.prefix, if (p.project) s.project.from else s.prefix.from,
    }) catch oom();
    if (nonEmpty(c.env.get("SLURM_JOB_ID"))) |job| {
        out.print(a, "# Checks first: Slurm job {s}, its own node-local {s} mount under {s},\n", .{ job, s.node_local_fstype.value, s.node_local_root.value }) catch oom();
    } else {
        out.appendSlice(a, "# Checks first: a Slurm job (there is none here, so a build would stop now),\n") catch oom();
        if (s.allocation_hint.value.len > 0) out.print(a, "#   for example: {s}\n", .{s.allocation_hint.value}) catch oom();
        out.print(a, "#   then its own node-local {s} mount under {s},\n", .{ s.node_local_fstype.value, s.node_local_root.value }) catch oom();
    }
    out.appendSlice(a, "#   and a prefix, sources and logs that are not on shared or node-local scratch.\n") catch oom();
    const jobs = batchLines(c, s, g, p, args);
    if (jobs.len > 0) {
        out.appendSlice(a, "# On each node type the site file lists in [build.node_types], the same build as a batch job:\n") catch oom();
        for (jobs) |line| out.print(a, "#   {s}\n", .{line}) catch oom();
    }
    out.appendSlice(a, "# W is a new workspace eb-local makes in that mount; it is removed after a good build.\n") catch oom();
    for (s.secrets.items) |sec| {
        if (config.buildGets(s, sec.name)) {
            out.print(a, "# {s} reaches eb's environment from {s}; logs are cleaned of it afterwards.\n", .{ sec.name, sec.source }) catch oom();
        } else {
            out.print(a, "# {s} stays out of eb's environment and is not read: build.secrets [{s}] does not name it.", .{ sec.name, s.build_secrets.from }) catch oom();
            if (config.withheldSource(s, sec)) |name| out.print(a, " {s}, the variable it comes from, stays out too.", .{name}) catch oom();
            out.append(a, '\n') catch oom();
        }
    }
    out.appendSlice(a, "# The script gets this environment without the install variables and") catch oom();
    for (shell_startup ++ host_loader) |name| out.print(a, " {s}", .{name}) catch oom();
    if (s.clear_foreign_prefixes.value)
        out.appendSlice(a, ",\n# and, because build.clear_foreign_prefixes is set, without entries of PERL5LIB, PYTHONPATH, R_LIBS*, CMAKE_PREFIX_PATH and PKG_CONFIG_PATH outside the approved prefixes, and without a compiler-wrapper variable that resolves outside them") catch oom();
    out.appendSlice(a, ",\n# and with these:\n") catch oom();
    for (buildVariables(a, "$W", d)) |kv| {
        if (std.mem.startsWith(u8, kv[1], "$W/")) {
            out.print(a, "export {s}=\"{s}\"\n", .{ kv[0], kv[1] }) catch oom();
        } else {
            out.print(a, "export {s}={s}\n", .{ kv[0], q(a, kv[1]) }) catch oom();
        }
    }
    for (s.eessi.items) |v| out.print(a, "export {s}={s}\n", .{ v.name, q(a, v.value) }) catch oom();
    if (s.site_toolchains.value.len > 0)
        out.print(a, "export EB_LOCAL_SITE_TOOLCHAINS={s}\n", .{q(a, config.toolchainsJson(a, s.site_toolchains.value) catch oom())}) catch oom();
    out.print(a, "umask {o:0>3}\n", .{buildUmask(p)}) catch oom();
    const argv = buildCommand(a, c, s, p, args);
    out.appendSlice(a, "# It runs in a clean bash (no profile, no rc file):\n#  ") catch oom();
    for (argv[0..4]) |x| out.print(a, " {s}", .{x}) catch oom();
    out.appendSlice(a, " \"$SCRIPT\"") catch oom();
    for (argv[5..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.appendSlice(a, "\n# where SCRIPT is everything after the next line.\nset --") catch oom();
    for (argv[6..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.print(a, "\n{s}\n", .{build_script}) catch oom();
    cli.put(1, out.items);
    return 0;
}

fn prefixCapacityOverride(c: Ctx) ?storage.Capacity {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_PREFIX_CAPACITY"))) |value| {
            const split = std.mem.indexOfScalar(u8, value, ':') orelse return null;
            return .{
                .bytes = std.fmt.parseInt(u64, value[0..split], 10) catch return null,
                .inodes = std.fmt.parseInt(u64, value[split + 1 ..], 10) catch return null,
            };
        }
    }
    return null;
}

fn prefixCapacity(c: Ctx, path: []const u8) ?storage.Capacity {
    return prefixCapacityOverride(c) orelse (storage.capacity(path) catch null);
}

fn cmdBuild(c: Ctx, s: config.Settings, g: Global, args: []const []const u8) u8 {
    const a = c.a;
    if (args.len == 0) {
        cli.err("{s}", .{usage_text});
        return 2;
    }
    if (g.explain) return explainBuild(c, s, g, args);
    if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null) {
        warn("not inside a Slurm job: SLURM_JOB_ID is unset or empty; nothing was built.", .{});
        cli.err("  Software is built for the CPU of the node that runs eb-local, so build\n", .{});
        cli.err("  inside an allocation on the node type that will run it{s}\n", .{if (s.allocation_hint.value.len > 0) ", for example:" else ""});
        if (s.allocation_hint.value.len > 0) cli.err("  {s}\n", .{s.allocation_hint.value});
        const jobs = batchLines(c, s, g, place(c, s), args);
        if (jobs.len > 0) cli.err("  or as a batch job, on each node type the site file lists:\n", .{});
        for (jobs) |line| cli.err("  {s}\n", .{line});
        return 2;
    }
    const job_root = checkedJobRoot(c, s, "nothing was built");
    var p = place(c, s);
    // The process umask EESSI-extend gives the install, as `eb-local eb`
    // sets it: 002 for a project, so that every member can write the
    // directories builds share, and 077 for a user. What eb-local makes
    // there takes it too.
    _ = linux.syscall1(.umask, buildUmask(p));
    const refused = refusedTrees(c, s, true);
    for (refused) |t| if (storage.under(p.prefix, t.path))
        die("the install prefix {s} [{s}] is under {s}, {s}; nothing was built.\n  " ++ outlive ++ "; " ++ prefix_fix ++ ".", .{ p.prefix, prefixFrom(s, p), t.path, t.what });
    common.atomic.makedirs(p.prefix) catch |e| die("installation prefix {s} is not writable ({s})", .{ p.prefix, storage.describeError(e) });
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = sys.z(&zb, p.prefix) catch |e| die("installation prefix {s} is not writable ({s})", .{ p.prefix, @errorName(e) });
        const acc_err = linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0));
        if (acc_err != .SUCCESS)
            die("installation prefix {s} is not writable ({s})", .{ p.prefix, sys.describeErrno(acc_err) });
        var buf: [sys.path_max]u8 = undefined;
        p.prefix = a.dupe(u8, fsx.realpath(fsx.cwd, p.prefix, &buf) catch |e| die("cannot resolve installation prefix {s} ({s})", .{ p.prefix, storage.describeError(e) })) catch oom();
    }
    if (prefixCapacity(c, p.prefix)) |cap| {
        if (cap.bytes == 0 or cap.inodes == 0)
            die("installation prefix {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ p.prefix, cap.bytes, cap.inodes });
    }
    const d = durableDirs(c, p.prefix, "nothing was built");
    // The trees a build writes below the prefix must not lead onto refused
    // storage either, through a symbolic link made later.
    for ([_][]const u8{ "versions", ".eb-local" }) |sub| {
        const path = std.fs.path.join(a, &.{ p.prefix, sub }) catch oom();
        const resolved = storage.canonical(a, path, c.cwd) catch oom();
        for (refused) |t| if (storage.under(resolved, t.path))
            die("{s} leads to {s}, under {s}, {s}; nothing was built.\n  " ++ outlive ++ ": replace the symbolic link in {s} with a directory, or " ++ prefix_fix ++ ".", .{ path, resolved, t.path, t.what, path });
    }

    {
        var shown: std.ArrayList(u8) = .empty;
        shown.appendSlice(a, replay(a, "--explain", s, g, p.prefix, &.{})) catch oom();
        for (args) |x| shown.print(a, " {s}", .{q(a, x)}) catch oom();
        say("eb-local: what this runs: eb-local {s}", .{shown.items});
    }

    // Secrets before the workspace and the build, so a missing one stops
    // the build with nothing but the installation directory made.
    var failure: secrets.Failure = .{};
    const wanted = config.buildSecrets(a, s) catch oom();
    for (wanted) |w| if (std.mem.startsWith(u8, w.source, "nimvault:"))
        warn("secret {s}: the nimvault: source is deprecated and is removed in 4.0.0; use file: or env:", .{w.name});
    const values = secrets.resolve(a, wanted, c.env, c.envp, nimvaultOf(s), &failure) catch |e| switch (e) {
        error.Unavailable => die("{s}", .{failure.message}),
        error.OutOfMemory => oom(),
    };
    for (values) |v| if (v.value.len < secrets.min_redacted_len)
        warn("secret {s} is shorter than {d} bytes and is not removed from logs", .{ v.name, secrets.min_redacted_len });

    const guard = Guard.hold();
    const work = storage.makeWorkspace(a, job_root) catch |e| workspaceFailed(a, job_root, e);
    for ([_][]const u8{ "build", "tmp", "cache", "cargo", "source-index" }) |sub|
        common.atomic.makedirs(std.fs.path.join(a, &.{ work, sub }) catch oom()) catch |e| {
            if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
            workspaceFailed(a, job_root, e);
        };
    common.atomic.makedirs(d.sources) catch |e| {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
        die("cannot create {s} ({s})", .{ d.sources, storage.describeError(e) });
    };
    common.atomic.makedirs(d.logs) catch |e| {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
        die("cannot create {s} ({s})", .{ d.logs, storage.describeError(e) });
    };
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zl = sys.z(&zb, d.logs) catch |e| {
            if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
            die("logs directory {s} is not writable ({s})", .{ d.logs, storage.describeError(e) });
        };
        _ = sys.call(linux.faccessat, .{ linux.AT.FDCWD, zl.ptr, linux.W_OK | linux.X_OK, 0 }) catch |e| {
            if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
            die("logs directory {s} is not writable ({s})", .{ d.logs, storage.describeError(e) });
        };
        if (values.len > 0) {
            // Logs may hold a secret until they are cleaned after the build.
            _ = sys.call(linux.fchmodat, .{ linux.AT.FDCWD, zl.ptr, @as(linux.mode_t, 0o700) }) catch |e| {
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                die("cannot make {s} private before a build with secrets ({s})", .{ d.logs, storage.describeError(e) });
            };
        }
    }
    const started: i64 = nowSecs();

    for (leftover_vars) |v| if (c.env.get(v)) |val| {
        if (ownInstallVar(c, s, p, v, val) == null)
            warn("{s}={s} is set in this shell; this build clears it, but EESSI-extend or eb run by hand would use it", .{ v, q(a, val) });
    };
    var prefix_lock: ?sys.fd_t = blk: {
        var lock_err: []const u8 = "";
        const timeout_ms = storage.lockTimeoutMs(c.env, &lock_err) orelse {
            if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
            die("{s}", .{lock_err});
        };
        const dir = std.fs.path.join(a, &.{ p.prefix, ".eb-local" }) catch oom();
        common.atomic.makedirs(dir) catch |e| {
            if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
            die("cannot create {s} ({s})", .{ dir, sys.describe(e) });
        };
        const lock_path = std.fs.path.join(a, &.{ dir, ".lock" }) catch oom();
        break :blk switch (storage.acquireBoundedLock(a, lock_path, timeout_ms, true, &lock_err)) {
            .held => |fd| fd,
            .unlocked => null,
            .failed => {
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                die("{s}", .{lock_err});
            },
        };
    };
    defer storage.releaseLock(&prefix_lock);
    const ws_lock_path = std.fs.path.join(a, &.{ work, ".eb-local.lock" }) catch oom();
    var ws_lock: ?sys.fd_t = storage.acquireOptionalLock(ws_lock_path);
    defer storage.releaseLock(&ws_lock);
    var env = c.env.clone(a) catch oom();
    for (install_vars) |v| _ = env.swapRemove(v);
    _ = env.swapRemove("EB_LOCAL_SITE_TOOLCHAINS");
    for (shell_startup) |name| _ = env.swapRemove(name);
    for (s.secrets.items) |sec| if (config.withheldSource(s, sec)) |name| {
        _ = env.swapRemove(name);
    };
    var dropped_loader = false;
    for (host_loader) |name| {
        const quiet = std.mem.eql(u8, name, "LD_PRELOAD") and onlyXalt(env.get(name) orelse "");
        if (env.swapRemove(name) and !quiet) dropped_loader = true;
    }
    if (dropped_loader) {
        warn("LD_LIBRARY_PATH, LD_PRELOAD or LD_AUDIT was set; a build does not pass them to eb,", .{});
        cli.err("  because they mix host libraries into the toolchain.\n", .{});
    }
    if (s.clear_foreign_prefixes.value) {
        const prefs = foreign.approvedPrefixes(a, c.env, s.approved_prefixes.value, p.prefix) catch oom();
        foreign.scrub(a, &env, prefs) catch oom();
    }
    if (s.site_toolchains.value.len > 0)
        env.put("EB_LOCAL_SITE_TOOLCHAINS", config.toolchainsJson(a, s.site_toolchains.value) catch oom()) catch oom();
    for (buildVariables(a, work, d)) |kv| env.put(kv[0], kv[1]) catch oom();
    for (s.eessi.items) |v| env.put(v.name, v.value) catch oom();
    for (values) |v| env.put(v.name, v.value) catch oom();

    if (guard.received()) |sig| {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
        guard.release();
        return stop(.{ .signal = sig });
    }
    // The guard stays until the logs are clean: a signal stops the build, but
    // eb-local first waits for EasyBuild, which writes them, to exit.
    const ran = guard.run(a, buildCommand(a, c, s, p, args), envpOf(a, &env));
    const rc: u8 = if (guard.received() != null) 1 else switch (ran) {
        .exit => |code| code,
        .signal => 1,
    };

    if (values.len > 0) {
        var report: secrets.RedactReport = .{};
        const tools: secrets.Tools = .{ .path = c.env.get("PATH") orelse "/usr/bin:/bin", .envp = c.envp };
        secrets.redactTree(a, d.logs, started, values, .all, tools, &report) catch |e| warn("cannot check {s} for secret values ({s}); inspect it before sharing", .{ d.logs, storage.describeError(e) });
        // EasyBuild keeps a copy of its log in each installation's easybuild/.
        const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
        secrets.redactTree(a, versions, started, values, .easybuild_dirs, tools, &report) catch |e| warn("cannot check {s} for secret values ({s}); inspect it before sharing", .{ versions, storage.describeError(e) });
        for (report.too_deep.items) |f| warn("{s} is too deep to check for secret values; inspect it before sharing", .{f});
        if (report.files > 0) say("eb-local: removed secret values from {d} log file(s)", .{report.files});
        for (report.too_large.items) |f| warn("{s} is too large to check for secret values; inspect it before sharing", .{f});
        for (report.unchecked.items) |f| warn("cannot check {s} for secret values ({s}); inspect it before sharing", .{ f.path, f.why });
        for (report.unchanged.items) |f| warn("cannot remove secret values from {s} ({s}); remove them before sharing", .{ f.path, f.why });
    }

    const keep = std.mem.eql(u8, c.env.get("EB_LOCAL_KEEP_WORK") orelse "", "1");
    if (rc == 0 and !keep) {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch |e|
            warn("cannot remove {s} ({s}); it goes when the allocation ends", .{ work, @errorName(e) });
    } else {
        warn("build workspace kept at {s}; it goes when the allocation ends,", .{work});
        cli.err("  or now with: eb-local clean --workspaces --no-logs\n", .{});
    }
    if (rc == 0) {
        say("", .{});
        say("eb-local: done. To use the modules in a new shell or job:", .{});
        say("  eval \"$(eb-local {s})\"", .{replay(a, "env", s, g, p.prefix, &.{})});
    }
    const ended: Run = if (guard.received()) |sig| .{ .signal = sig } else ran;
    guard.release();
    storage.releaseLock(&ws_lock);
    storage.releaseLock(&prefix_lock);
    return stop(ended);
}

// ---- list -----------------------------------------------------------------

/// Each installation tree EESSI-extend made below PATH: one per EESSI version
/// and CPU target, holding software/ and modules/all/. Symbolic links are not
/// followed.
fn findTrees(c: Ctx, path: []const u8, out: *std.ArrayList([]const u8), depth: usize) void {
    if (depth > 12) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    if (isDirAt(fd, "software") and isDirAt(fd, "modules")) {
        out.append(c.a, path) catch oom();
        return;
    }
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        if (!isDirAt(fd, e.name)) continue;
        findTrees(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), out, depth + 1);
    }
}

/// The CPU target a tree is for: what follows software/linux/ in its path.
fn treeTarget(tree: []const u8) []const u8 {
    const key = "/software/linux/";
    const i = std.mem.lastIndexOf(u8, tree, key) orelse return tree;
    return tree[i + key.len ..];
}

/// The EESSI version a tree is for: the directory below versions/.
fn treeVersion(versions: []const u8, tree: []const u8) []const u8 {
    if (tree.len <= versions.len + 1) return "";
    const rest = tree[versions.len + 1 ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

/// NAME/VERSION of every module file in a tree's modules/all.
fn treeModules(c: Ctx, tree: []const u8, out: *std.ArrayList([]const u8)) void {
    const all = std.fs.path.join(c.a, &.{ tree, "modules", "all" }) catch oom();
    const fd = fsx.openDir(fsx.cwd, all, false) catch return;
    defer sys.close(fd);
    var names = fsx.DirIter.init(c.a, fd) catch return;
    while (names.next() catch null) |n| {
        if (n.name.len == 0 or n.name[0] == '.' or !isDirAt(fd, n.name)) continue;
        const name = c.a.dupe(u8, n.name) catch oom();
        const nfd = fsx.openDir(fd, name, false) catch continue;
        defer sys.close(nfd);
        var files = fsx.DirIter.init(c.a, nfd) catch continue;
        while (files.next() catch null) |f| {
            if (f.name.len == 0 or f.name[0] == '.' or !std.mem.endsWith(u8, f.name, ".lua")) continue;
            const st = fsx.statAt(nfd, f.name, false) catch continue;
            if (!st.isReg()) continue;
            out.append(c.a, str(c.a, "{s}/{s}", .{ name, f.name[0 .. f.name.len - 4] })) catch oom();
        }
    }
}

const Listed = struct {
    module: []const u8,
    at: std.ArrayList(usize) = .empty,
};

fn listedLess(_: void, x: Listed, y: Listed) bool {
    return std.mem.lessThan(u8, x.module, y.module);
}

fn matchesFilter(module: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| {
        if (std.mem.eql(u8, module, f)) return true;
        if (std.mem.endsWith(u8, f, "/")) {
            if (f.len > 1 and std.mem.startsWith(u8, module, f)) return true;
        } else if (module.len > f.len and std.mem.startsWith(u8, module, f) and module[f.len] == '/') {
            return true;
        }
    }
    return false;
}

test "matchesFilter matches NAME, NAME/, and NAME/VERSION" {
    try std.testing.expect(matchesFilter("demo/1.0", &.{"demo"}));
    try std.testing.expect(matchesFilter("demo/1.0", &.{"demo/"}));
    try std.testing.expect(matchesFilter("demo/1.0", &.{"demo/1.0"}));
    try std.testing.expect(!matchesFilter("demo2/1.0", &.{"demo/"}));
    try std.testing.expect(!matchesFilter("demo/1.0", &.{"/"}));
}

const ListTargetJson = struct { label: []const u8, here: bool };
const ListModuleJson = struct { name: []const u8, built: []const bool };
const ListReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "list",
    prefix: []const u8,
    filters: []const []const u8,
    empty: bool,
    targets: []const ListTargetJson,
    modules: []const ListModuleJson,
    node_target: ?[]const u8 = null,
    missing_on_node: []const []const u8,
    hint: ?[]const u8 = null,
};

/// What is installed in the prefix, for which CPU targets, and what the
/// target of this node lacks.
fn cmdList(c: Ctx, s: config.Settings, filters: []const []const u8, json: bool, missing_only: bool) u8 {
    const a = c.a;
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    var trees: std.ArrayList([]const u8) = .empty;
    if (literalPath(c, versions)) findTrees(c, versions, &trees, 0);
    std.mem.sort([]const u8, trees.items, {}, lessThanStr);

    var several_versions = false;
    for (trees.items) |t| {
        if (!std.mem.eql(u8, treeVersion(versions, t), treeVersion(versions, trees.items[0]))) several_versions = true;
    }
    // A column for each tree, named by the last part of its target unless
    // two trees would share that name.
    var labels: std.ArrayList([]const u8) = .empty;
    for (trees.items) |t| {
        const target = treeTarget(t);
        const short = std.fs.path.basename(target);
        var clash = false;
        for (trees.items) |u| {
            if (u.ptr != t.ptr and std.mem.eql(u8, std.fs.path.basename(treeTarget(u)), short)) clash = true;
        }
        const base = if (clash) target else short;
        labels.append(a, if (several_versions) str(a, "{s}:{s}", .{ treeVersion(versions, t), base }) else base) catch oom();
    }

    var rows: std.ArrayList(Listed) = .empty;
    for (trees.items, 0..) |t, ti| {
        var mods: std.ArrayList([]const u8) = .empty;
        treeModules(c, t, &mods);
        for (mods.items) |m| {
            if (!matchesFilter(m, filters)) continue;
            const row = for (rows.items) |*r| {
                if (std.mem.eql(u8, r.module, m)) break r;
            } else blk: {
                rows.append(a, .{ .module = m }) catch oom();
                break :blk &rows.items[rows.items.len - 1];
            };
            row.at.append(a, ti) catch oom();
        }
    }
    std.mem.sort(Listed, rows.items, {}, listedLess);

    // This node's target, when EESSI is loaded.
    const raw_here = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR"));
    const here_target = if (raw_here) |ht| blk: {
        const trimmed = std.mem.trimEnd(u8, ht, "/");
        break :blk if (trimmed.len > 0) trimmed else ht;
    } else null;
    const here_version = nonEmpty(c.env.get("EESSI_VERSION"));
    var here: ?usize = null;
    if (here_target) |ht| for (trees.items, 0..) |t, ti| {
        if (!std.mem.eql(u8, treeTarget(t), ht)) continue;
        if (here_version) |hv| if (!std.mem.eql(u8, treeVersion(versions, t), hv)) continue;
        here = ti;
    };

    if (missing_only) {
        if (here_target == null) die("list --missing needs EESSI loaded (eval \"$(eb-local env)\") to know this node's CPU target", .{});
        var out: std.ArrayList(u8) = .empty;
        for (rows.items) |r| {
            if (here == null or std.mem.indexOfScalar(usize, r.at.items, here.?) == null) {
                out.appendSlice(a, r.module) catch oom();
                out.append(a, '\n') catch oom();
            }
        }
        cli.put(1, out.items);
        return 0;
    }

    if (json) {
        var missing_on_node: std.ArrayList([]const u8) = .empty;
        var hint: ?[]const u8 = null;
        if (here) |hi| {
            for (rows.items) |r| if (std.mem.indexOfScalar(usize, r.at.items, hi) == null)
                missing_on_node.append(a, r.module) catch oom();
        } else if (here_target) |ht| {
            for (rows.items) |r| missing_on_node.append(a, r.module) catch oom();
            if (rows.items.len > 0)
                hint = str(a, "Nothing is built for this node's target, {s}, yet; build in an allocation on this node type.", .{ht});
        } else {
            hint = "Load EESSI (eval \"$(eb-local env)\") to see what this node's CPU target lacks.";
        }
        var targets: std.ArrayList(ListTargetJson) = .empty;
        for (labels.items, 0..) |l, li|
            targets.append(a, .{ .label = l, .here = here != null and here.? == li }) catch oom();
        var modules: std.ArrayList(ListModuleJson) = .empty;
        for (rows.items) |r| {
            var built: std.ArrayList(bool) = .empty;
            for (0..labels.items.len) |li|
                built.append(a, std.mem.indexOfScalar(usize, r.at.items, li) != null) catch oom();
            modules.append(a, .{ .name = r.module, .built = built.items }) catch oom();
        }
        jsonout.emit(a, ListReport{
            .prefix = p.prefix,
            .filters = filters,
            .empty = trees.items.len == 0 or rows.items.len == 0,
            .targets = targets.items,
            .modules = modules.items,
            .node_target = here_target,
            .missing_on_node = missing_on_node.items,
            .hint = hint,
        });
        return 0;
    }

    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    if (trees.items.len == 0 or rows.items.len == 0) {
        add(a, &out, str(a, "Nothing{s} is installed in {s}.\n", .{ if (filters.len > 0) " that matches" else "", p.prefix }));
        cli.put(1, out.items);
        return 0;
    }

    var width: usize = "MODULE".len;
    for (rows.items) |r| width = @max(width, r.module.len);
    add(a, &out, str(a, "{s}: {d} module(s) for {d} CPU target(s)\n", .{ p.prefix, rows.items.len, trees.items.len }));
    add(a, &out, "MODULE");
    for (0..width - "MODULE".len + 2) |_| add(a, &out, " ");
    for (labels.items, 0..) |l, li| add(a, &out, str(a, "{s}{s}  ", .{ l, if (here != null and here.? == li) "*" else "" }));
    while (out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    add(a, &out, "\n");
    for (rows.items) |r| {
        add(a, &out, r.module);
        for (0..width - r.module.len + 2) |_| add(a, &out, " ");
        for (labels.items, 0..) |l, li| {
            const has = std.mem.indexOfScalar(usize, r.at.items, li) != null;
            add(a, &out, if (has) "x" else "-");
            const cell = l.len + @as(usize, if (here != null and here.? == li) 1 else 0);
            for (0..cell + 1) |_| add(a, &out, " ");
        }
        // No trailing blanks on a row.
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        add(a, &out, "\n");
    }
    if (here) |hi| {
        var missing: std.ArrayList([]const u8) = .empty;
        for (rows.items) |r| if (std.mem.indexOfScalar(usize, r.at.items, hi) == null) missing.append(a, r.module) catch oom();
        if (missing.items.len == 0) {
            add(a, &out, str(a, "Every module listed is built for this node's target, {s} (*).\n", .{here_target.?}));
        } else {
            add(a, &out, str(a, "Not built for this node's target, {s} (*): {s}.\n", .{ here_target.?, std.mem.join(a, ", ", missing.items) catch oom() }));
            add(a, &out, "Build them in an allocation on this node type; each target needs its own build.\n");
        }
    } else if (here_target) |ht| {
        add(a, &out, str(a, "Nothing is built for this node's target, {s}, yet; build in an allocation on this node type.\n", .{ht}));
    } else {
        add(a, &out, "Load EESSI (eval \"$(eb-local env)\") to see what this node's CPU target lacks.\n");
    }
    cli.put(1, out.items);
    return 0;
}

// ---- doctor ---------------------------------------------------------------

const DoctorLine = struct {
    level: []const u8,
    text: []const u8,
};

const DoctorReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "doctor",
    site_file: bool,
    failed: bool,
    lines: []const DoctorLine,
    summary: []const u8,
};

fn doctorLevel(kind: []const u8) []const u8 {
    return std.mem.trim(u8, kind, " ");
}

fn mountinfoSoft(c: Ctx) []const u8 {
    var path: []const u8 = "/proc/self/mountinfo";
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_MOUNTINFO"))) |p| path = p;
    }
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch return "";
    defer sys.close(fd);
    return fsx.readAll(c.a, fd, 8 << 20) catch "";
}

fn reportForeign(c: Ctx, s: config.Settings, prefix: []const u8, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) void {
    const a = c.a;
    const prefs = foreign.approvedPrefixes(a, c.env, s.approved_prefixes.value, prefix) catch oom();
    const found = foreign.scan(a, c.env, prefs, s.clear_foreign_prefixes.value, mountinfoSoft(c)) catch oom();
    for (found) |f| switch (f.code) {
        .none => note(a, out, json_lines, "info", "no PERL5LIB, PYTHONPATH, R_LIBS*, CMAKE_PREFIX_PATH or PKG_CONFIG_PATH entry, and no compiler-wrapper variable, points outside the approved prefixes", .{}),
        .list_keep => note(a, out, json_lines, "warn", "{s} entry {s} is outside the approved prefixes; a build keeps it until build.clear_foreign_prefixes is set", .{ f.name, f.path }),
        .list_drop => note(a, out, json_lines, "warn", "{s} entry {s} is outside the approved prefixes; a build drops it because build.clear_foreign_prefixes is set", .{ f.name, f.path }),
        .wrap_keep => note(a, out, json_lines, "warn", "{s} resolves to {s}, outside the approved prefixes; a build keeps it until build.clear_foreign_prefixes is set", .{ f.name, f.path }),
        .wrap_drop => note(a, out, json_lines, "warn", "{s} resolves to {s}, outside the approved prefixes; a build unsets it because build.clear_foreign_prefixes is set", .{ f.name, f.path }),
        .timezone => note(a, out, json_lines, "info", "timezone target {s}", .{f.path}),
        .timezone_bind => note(a, out, json_lines, "warn", "/etc/localtime is a bind mount of {s}; the runtime injected the host timezone", .{f.path}),
        .host_lib => note(a, out, json_lines, "warn", "runtime-injected host library directory {s}", .{f.path}),
        .host_none => note(a, out, json_lines, "info", "no runtime-injected host library directory was found", .{}),
    };
}

fn note(a: Allocator, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine), kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    const text = str(a, fmt, args);
    if (json_lines) |lines| {
        lines.append(a, .{ .level = doctorLevel(kind), .text = text }) catch oom();
        return;
    }
    out.appendSlice(a, kind) catch oom();
    out.appendSlice(a, " ") catch oom();
    out.appendSlice(a, text) catch oom();
    out.appendSlice(a, "\n") catch oom();
}

const DoctorOpts = struct {
    /// `--strict`: treat `warn` lines as failures alongside `FAIL`.
    strict: bool = false,
    /// `--cvmfs`: check the client. Off unless the flag asks.
    cvmfs: bool = false,
    /// `--cvmfs-parallel`. Null uses `doctor.cvmfs_parallel`.
    parallel: ?u8 = null,
    /// `--mpi`: report fabrics and, in an allocation, run the hello. Off unless the flag asks.
    mpi: bool = false,
    /// `--workspace`: exercise and describe this existing build workspace.
    workspace: ?[]const u8 = null,
};

fn workspaceCapacityOverride(c: Ctx) ?storage.Capacity {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_WORKSPACE_CAPACITY"))) |value| {
            const split = std.mem.indexOfScalar(u8, value, ':') orelse return null;
            return .{
                .bytes = std.fmt.parseInt(u64, value[0..split], 10) catch return null,
                .inodes = std.fmt.parseInt(u64, value[split + 1 ..], 10) catch return null,
            };
        }
    }
    return null;
}

fn workspaceExecuteOverride(c: Ctx) ?bool {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_WORKSPACE_EXEC"))) |value| {
            if (std.mem.eql(u8, value, "ok")) return true;
            if (std.mem.eql(u8, value, "fail")) return false;
        }
    }
    return null;
}

/// Create, write, rename, execute and remove a probe, then describe the
/// workspace's mount, capacity and effective user cache. A build is not run.
fn reportWorkspace(c: Ctx, s: config.Settings, raw_path: []const u8, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) bool {
    const a = c.a;
    if (!std.fs.path.isAbsolute(raw_path)) {
        note(a, out, json_lines, "FAIL", "workspace {s} is not an absolute path", .{raw_path});
        return true;
    }
    const path = storage.canonical(a, raw_path, c.cwd) catch {
        note(a, out, json_lines, "FAIL", "workspace {s} cannot be resolved", .{raw_path});
        return true;
    };
    const stat = fsx.statAt(fsx.cwd, path, true) catch |err| {
        note(a, out, json_lines, "FAIL", "workspace {s} cannot be read ({s})", .{ path, @errorName(err) });
        return true;
    };
    if (!stat.isDir()) {
        note(a, out, json_lines, "FAIL", "workspace {s} is not a directory", .{path});
        return true;
    }
    const mount = (storage.mountOf(a, mountinfoSoft(c), path) catch null) orelse {
        note(a, out, json_lines, "FAIL", "workspace {s} is not covered by a readable mount table entry", .{path});
        return true;
    };
    var failed = false;
    const probe: ?storage.WorkspaceProbe = storage.probeWorkspace(c.io, a, path, workspaceExecuteOverride(c)) catch |err| blk: {
        note(a, out, json_lines, "FAIL", "workspace {s} probe could not complete ({s})", .{ path, @errorName(err) });
        failed = true;
        break :blk null;
    };
    if (probe) |p| {
        if (p.created and p.written and p.renamed and p.executed and p.removed) {
            note(a, out, json_lines, "ok  ", "workspace {s}: created, wrote, renamed, executed and removed a probe", .{path});
        } else {
            note(a, out, json_lines, "FAIL", "workspace {s}: probe create={s}, write={s}, rename={s}, execute={s}, remove={s}", .{
                path,
                if (p.created) "ok" else "failed",
                if (p.written) "ok" else "failed",
                if (p.renamed) "ok" else "failed",
                if (p.executed) "ok" else "failed",
                if (p.removed) "ok" else "failed",
            });
            failed = true;
        }
    }
    const class = storage.workspaceClass(path, mount.fstype, s.shared_scratch.value);
    note(a, out, json_lines, "info", "workspace {s}: {s} file system, classified {s}", .{ path, mount.fstype, class });
    const available: ?storage.Capacity = workspaceCapacityOverride(c) orelse storage.capacity(path) catch |err| blk: {
        note(a, out, json_lines, "FAIL", "workspace {s}: free bytes and inodes cannot be read ({s})", .{ path, @errorName(err) });
        failed = true;
        break :blk null;
    };
    if (available) |free| {
        if (free.bytes == 0 or free.inodes == 0) {
            note(a, out, json_lines, "FAIL", "workspace {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ path, free.bytes, free.inodes });
            failed = true;
        } else note(a, out, json_lines, "info", "workspace {s}: {d} free bytes, {d} free inodes", .{ path, free.bytes, free.inodes });
    }
    if (storage.hasMountOption(mount.options, "noexec")) {
        note(a, out, json_lines, "FAIL", "workspace {s}: mount {s} has noexec", .{ path, mount.target });
        failed = true;
    } else note(a, out, json_lines, "ok  ", "workspace {s}: mount {s} does not have noexec", .{ path, mount.target });
    if (rpath.cacheHome(a, c.env)) |cache| {
        const canonical_cache = storage.canonical(a, cache, c.cwd) catch cache;
        if (storage.under(canonical_cache, path)) {
            note(a, out, json_lines, "ok  ", "effective XDG cache {s} is private to workspace {s}", .{ canonical_cache, path });
        } else note(a, out, json_lines, "warn", "effective XDG cache {s} is outside workspace {s}", .{ canonical_cache, path });
    } else |_| note(a, out, json_lines, "warn", "effective XDG cache is unavailable: XDG_CACHE_HOME, or HOME for its .cache, must be absolute", .{});
    return failed;
}

fn cvmfsConfigRoot(c: Ctx) []const u8 {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_CVMFS_CONFIG"))) |p| return p;
    }
    return "/etc/cvmfs";
}

fn cvmfsMountOverride(c: Ctx) ?[]const u8 {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_CVMFS_ERRNO"))) |v| return v;
    }
    return null;
}

/// The CernVM-FS client: the mount, the proxy in force, `cvmfs_config` when
/// it is on PATH, and an optional metadata read. Returns whether a line said
/// FAIL. A build does not run this.
fn reportCvmfs(c: Ctx, tasks: u8, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) bool {
    const a = c.a;
    const repo = cvmfs.repository(c.env);
    const mount = cvmfs.mountState(repo.path, cvmfsMountOverride(c));
    var failed = false;
    switch (mount) {
        .ok => note(a, out, json_lines, "ok  ", "CernVM-FS repository {s} is mounted", .{repo.path}),
        .enotconn => {
            note(a, out, json_lines, "FAIL", "CernVM-FS repository {s} is a stale FUSE mount: transport endpoint is not connected", .{repo.path});
            failed = true;
        },
        .eio => note(a, out, json_lines, "warn", "CernVM-FS repository {s} returned an input/output error", .{repo.path}),
        .absent => note(a, out, json_lines, "info", "CernVM-FS repository {s} is not mounted", .{repo.path}),
    }
    const proxy = cvmfs.readProxy(a, c.env, cvmfsConfigRoot(c), repo.name) catch oom();
    switch (proxy.mode) {
        .unset => note(a, out, json_lines, "info", "CernVM-FS HTTP proxy is unset", .{}),
        .direct => if (proxy.host_injected) {
            note(a, out, json_lines, "warn", "CernVM-FS HTTP proxy mode is direct, from environment CVMFS_HTTP_PROXY; a host can inject this", .{});
        } else note(a, out, json_lines, "info", "CernVM-FS HTTP proxy mode is direct, from {s}", .{proxy.from}),
        .proxy => if (proxy.host_injected) {
            note(a, out, json_lines, "warn", "CernVM-FS HTTP proxy {s}, from environment CVMFS_HTTP_PROXY; a host can inject this", .{proxy.value});
        } else note(a, out, json_lines, "info", "CernVM-FS HTTP proxy {s}, from {s}", .{ proxy.value, proxy.from }),
    }
    const path_env = c.env.get("PATH") orelse "";
    if (proc.which(a, "cvmfs_config", path_env) catch null) |exe| {
        if (mount == .enotconn) {
            note(a, out, json_lines, "info", "cvmfs_config probe was not run; the mount is stale", .{});
        } else {
            const probe = cvmfs.runTool(a, exe, &.{ exe, "probe", repo.name }, c.envp);
            if (probe.timed_out) {
                note(a, out, json_lines, "warn", "cvmfs_config probe {s} timed out", .{repo.name});
            } else if (probe.code == 0) {
                note(a, out, json_lines, "ok  ", "cvmfs_config probe {s} exited 0", .{repo.name});
            } else note(a, out, json_lines, "warn", "cvmfs_config probe {s} exited {d}", .{ repo.name, probe.code });
        }
        const check = cvmfs.runTool(a, exe, &.{ exe, "chksetup" }, c.envp);
        if (check.timed_out) {
            note(a, out, json_lines, "warn", "cvmfs_config chksetup timed out", .{});
        } else if (check.code == 0) {
            note(a, out, json_lines, "ok  ", "cvmfs_config chksetup exited 0", .{});
        } else note(a, out, json_lines, "warn", "cvmfs_config chksetup exited {d}", .{check.code});
    } else note(a, out, json_lines, "info", "cvmfs_config is not on PATH, so probe and chksetup were not run", .{});
    if (tasks > 0) {
        const srun = proc.which(a, "srun", path_env) catch null;
        const ran = cvmfs.parallelProbe(a, repo.path, tasks, nonEmpty(c.env.get("SLURM_JOB_ID")) != null, mount == .enotconn, srun, c.envp);
        switch (ran.kind) {
            .off => {},
            .stale => note(a, out, json_lines, "info", "parallel metadata read was not run; the mount is stale", .{}),
            .outside => note(a, out, json_lines, "info", "parallel metadata read of {d} tasks runs only inside an allocation", .{ran.tasks}),
            .srun_ok => note(a, out, json_lines, "ok  ", "srun -n {d} read metadata of {s}", .{ ran.tasks, repo.path }),
            .srun_fail => note(a, out, json_lines, "warn", "srun -n {d} read metadata of {s} and exited {d}", .{ ran.tasks, repo.path, ran.code }),
            .srun_timeout => note(a, out, json_lines, "warn", "srun -n {d} read metadata of {s} and timed out", .{ ran.tasks, repo.path }),
            .fork_ok => note(a, out, json_lines, "ok  ", "parallel metadata read of {d} tasks on {s}", .{ ran.tasks, repo.path }),
            .fork_fail => note(a, out, json_lines, "warn", "parallel metadata read of {d} tasks on {s}: {d} failed", .{ ran.tasks, repo.path, ran.code }),
        }
    }
    return failed;
}

fn bindWord(c: Ctx, name: []const u8) []const u8 {
    return nonEmpty(c.env.get(name)) orelse "unset";
}

/// libfabric, UCX and Slurm binding, then a two-rank hello for each
/// site-approved transport. The hello's variables are not put in this
/// process, and a build does not set them. Nothing here is a FAIL.
fn reportMpi(c: Ctx, s: config.Settings, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) void {
    const a = c.a;
    const path_env = c.env.get("PATH") orelse "";
    if (proc.which(a, "fi_info", path_env) catch null) |exe| {
        const info = mpi.summarize(a, exe, &.{ exe, "-l" }, c.envp);
        if (info.timed_out) {
            note(a, out, json_lines, "warn", "fi_info timed out", .{});
        } else if (info.code != 0) {
            note(a, out, json_lines, "warn", "fi_info exited {d}", .{info.code});
        } else note(a, out, json_lines, "info", "fi_info: {s}", .{info.line});
    } else note(a, out, json_lines, "info", "fi_info is not on PATH", .{});
    if (proc.which(a, "ucx_info", path_env) catch null) |exe| {
        const info = mpi.summarize(a, exe, &.{ exe, "-v" }, c.envp);
        if (info.timed_out) {
            note(a, out, json_lines, "warn", "ucx_info timed out", .{});
        } else if (info.code != 0) {
            note(a, out, json_lines, "warn", "ucx_info exited {d}", .{info.code});
        } else note(a, out, json_lines, "info", "ucx_info: {s}", .{info.line});
    } else note(a, out, json_lines, "info", "ucx_info is not on PATH", .{});
    const cpu = bindWord(c, "SLURM_CPU_BIND");
    const list = bindWord(c, "SLURM_CPU_BIND_LIST");
    const mem = bindWord(c, "SLURM_MEM_BIND");
    if (std.mem.eql(u8, cpu, "unset") and std.mem.eql(u8, list, "unset") and std.mem.eql(u8, mem, "unset")) {
        note(a, out, json_lines, "info", "no Slurm CPU or memory bind is set", .{});
    } else note(a, out, json_lines, "info", "Slurm bind SLURM_CPU_BIND={s} SLURM_CPU_BIND_LIST={s} SLURM_MEM_BIND={s}", .{ cpu, list, mem });

    if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null) {
        note(a, out, json_lines, "info", "MPI hello was not compiled; this shell is not inside an allocation", .{});
        return;
    }
    if (s.mpi_transports.value.len == 0) {
        note(a, out, json_lines, "info", "no site-approved MPI transport is configured", .{});
        return;
    }
    const mpicc = proc.which(a, "mpicc", path_env) catch null;
    const mpirun = proc.which(a, "mpirun", path_env) catch null;
    if (mpicc == null) {
        note(a, out, json_lines, "info", "mpicc is not on PATH, so the MPI hello was not compiled", .{});
        return;
    }
    const tmp = nonEmpty(c.env.get("TMPDIR")) orelse "/tmp";
    const base = if (fsx.statAt(fsx.cwd, tmp, true)) |st| (if (st.isDir()) tmp else "/tmp") else |_| "/tmp";
    const work = storage.makeWorkspace(a, base) catch {
        note(a, out, json_lines, "warn", "MPI hello was not compiled; {s} could not be created", .{base});
        return;
    };
    defer fsx.deleteTree(a, fsx.cwd, work) catch {};
    var seen_ofi = false;
    var seen_ucx = false;
    for (s.mpi_transports.value) |name| {
        const transport = mpi.parseTransport(name) orelse continue;
        switch (transport) {
            .ofi => {
                if (seen_ofi) continue;
                seen_ofi = true;
            },
            .ucx => {
                if (seen_ucx) continue;
                seen_ucx = true;
            },
        }
        const hello = mpi.runHello(a, transport, mpicc, mpirun, work, c.env, c.envp) catch oom();
        const label = @tagName(transport);
        if (hello.source_error) |msg| {
            note(a, out, json_lines, "warn", "MPI hello could not be written ({s})", .{msg});
            return;
        }
        if (hello.missing_compiler) {
            note(a, out, json_lines, "info", "mpicc is not on PATH, so the MPI hello was not compiled", .{});
            return;
        }
        if (hello.compile_timeout) {
            note(a, out, json_lines, "warn", "mpicc for {s} timed out", .{label});
            continue;
        }
        if (hello.compile_code != 0) {
            note(a, out, json_lines, "warn", "mpicc for {s} exited {d}", .{ label, hello.compile_code });
            continue;
        }
        if (hello.missing_launcher) {
            note(a, out, json_lines, "info", "mpirun is not on PATH, so the MPI hello was not run", .{});
            return;
        }
        if (hello.run_timeout) {
            note(a, out, json_lines, "warn", "mpirun for {s} timed out", .{label});
            continue;
        }
        if (hello.run_code != 0) {
            note(a, out, json_lines, "warn", "mpirun for {s} exited {d}", .{ label, hello.run_code });
            continue;
        }
        if (hello.ranks.len != 2 or hello.ranks[0].size != 2 or hello.ranks[1].size != 2) {
            note(a, out, json_lines, "warn", "MPI {s} hello did not report two ranks", .{label});
            continue;
        }
        if (mpi.sharedCpu(hello.ranks)) {
            note(a, out, json_lines, "warn", "MPI {s} hello ranks share cpu {d} with {s}", .{ label, hello.ranks[0].cpu, hello.override_text });
            continue;
        }
        const cpus = std.fmt.allocPrint(a, "{d},{d}", .{ hello.ranks[0].cpu, hello.ranks[1].cpu }) catch oom();
        note(a, out, json_lines, "ok  ", "MPI {s} hello size {d} on cpus {s} with {s}", .{ label, hello.ranks[0].size, cpus, hello.override_text });
    }
}

fn hasDoctorWarning(out: []const u8, json_lines: []const DoctorLine, json: bool) bool {
    if (json) {
        for (json_lines) |l| if (std.mem.eql(u8, l.level, "warn")) return true;
        return false;
    }
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "warn ")) return true;
    }
    return false;
}

/// Everything about this shell, this node and the configuration that would
/// make a build, `eb-local eb` or a module load go wrong, one line each: ok,
/// info, warn or FAIL. Changes nothing; exits 1 when a line says FAIL. A
/// build needs a site file and `eb-local eb` does not, so without one what
/// stops `eb-local eb` is a FAIL, and with one what stops a build is.
fn cmdDoctor(c: Ctx, s: config.Settings, g: Global, opts: DoctorOpts) u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    var json_lines: std.ArrayList(DoctorLine) = .empty;
    const lines_ptr: ?*std.ArrayList(DoctorLine) = if (g.json_out) &json_lines else null;
    var failed = false;
    note(a, &out, lines_ptr, "ok  ", "eb-local {s}", .{version});

    // Configuration.
    const sources = configSources(c, g);
    for (sources) |src| note(a, &out, lines_ptr, "ok  ", "{s} file {s}", .{ @tagName(src.layer), src.path });
    const site = s.node_local_root.value.len > 0;
    if (site) {
        note(a, &out, lines_ptr, "ok  ", "builds use the allocation's own {s} mount {s}/{s}", .{ s.node_local_fstype.value, s.node_local_root.value, s.node_local_mount.value });
    } else {
        note(a, &out, lines_ptr, "info", "no site file sets storage.node_local_root: `eb-local RECIPE` needs a site file; `eb-local eb` does not. `eb-local site install` writes one beside the program", .{});
    }

    // A build reads each secret it gets before it starts, so one of those
    // that cannot be read stops it, whether or not eb uses it. The values
    // are read as a build reads them and never shown.
    for (s.secrets.items) |sec| {
        const gets = config.buildGets(s, sec.name);
        var f: secrets.Failure = .{};
        if (secrets.resolve(a, &.{sec}, c.env, c.envp, nimvaultOf(s), &f)) |values| {
            if (values[0].value.len < secrets.min_redacted_len) {
                note(a, &out, lines_ptr, "warn", "secret {s} from {s} is shorter than {d} bytes and is not removed from logs", .{ sec.name, sec.source, secrets.min_redacted_len });
            } else if (gets) {
                note(a, &out, lines_ptr, "ok  ", "secret {s} can be read from {s}", .{ sec.name, sec.source });
            } else note(a, &out, lines_ptr, "info", "secret {s} can be read from {s}; builds do not get it, as build.secrets [{s}] does not name it", .{ sec.name, sec.source, s.build_secrets.from });
        } else |e| switch (e) {
            error.Unavailable => if (!gets) {
                note(a, &out, lines_ptr, "warn", "{s} [{s}]; builds do not read it, as build.secrets [{s}] does not name it, but one that names it stops there", .{ f.message, sec.from, s.build_secrets.from });
            } else {
                if (s.build_secrets.value == null) {
                    note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "{s} [{s}]; every build stops there, whether or not it uses {s}. " ++
                        "Name in build.secrets the secrets builds need, or in EB_LOCAL_BUILD_SECRETS those one build needs", .{ f.message, sec.from, sec.name });
                } else note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "{s} [{s}]; every build stops there, as build.secrets [{s}] names {s}", .{ f.message, sec.from, s.build_secrets.from, sec.name });
                if (site) failed = true;
            },
            error.OutOfMemory => oom(),
        }
    }

    // Where installs go.
    const p = locate(c, s);
    note(a, &out, lines_ptr, "ok  ", "installs go to {s}: a {s} install, prefix from {s}", .{ p.prefix, if (p.project) "project" else "user", if (p.project) s.project.from else s.prefix.from });
    for (refusedTrees(c, s, false)) |t| if (t.path.len > 0 and storage.under(p.prefix, t.path)) {
        note(a, &out, lines_ptr, "FAIL", "the install prefix {s} [{s}] is under {s}, {s}; builds refuse it. " ++ outlive ++ "; " ++ prefix_fix, .{ p.prefix, prefixFrom(s, p), t.path, t.what });
        failed = true;
    };
    if (fsx.statAt(fsx.cwd, p.prefix, true)) |st| {
        var zb: [sys.path_max:0]u8 = undefined;
        const acc_err: ?linux.E = if (sys.z(&zb, p.prefix)) |zp| blk: {
            const err = linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0));
            break :blk if (err == .SUCCESS) null else err;
        } else |_| .NAMETOOLONG;
        if (!st.isDir()) {
            note(a, &out, lines_ptr, "FAIL", "{s} is not a directory", .{p.prefix});
            failed = true;
        } else if (acc_err) |ae| {
            note(a, &out, lines_ptr, "FAIL", "you cannot write to {s} ({s})", .{ p.prefix, sys.describeErrno(ae) });
            failed = true;
        } else if (prefixCapacity(c, p.prefix)) |cap| {
            if (cap.bytes == 0 or cap.inodes == 0) {
                note(a, &out, lines_ptr, "FAIL", "installation prefix {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ p.prefix, cap.bytes, cap.inodes });
                failed = true;
            }
        }
        if (p.project and st.isDir()) {
            if (st.mode & 0o002 != 0) {
                note(a, &out, lines_ptr, "FAIL", "project directory {s} is writable by others; anyone could add modules the group loads. chmod o-w it", .{p.prefix});
                failed = true;
            }
            if (st.mode & 0o2000 == 0) note(a, &out, lines_ptr, "warn", "project directory {s} has no setgid bit, so installs keep the installer's group; chmod g+s it", .{p.prefix});
        }
    } else |_| {
        if (p.project) {
            note(a, &out, lines_ptr, "FAIL", "project directory {s} does not exist; the project owner creates it with the project group and chmod 2770", .{p.prefix});
            failed = true;
        } else {
            var ancestor: []const u8 = p.prefix;
            while (ancestor.len > 1) {
                if (fsx.statAt(fsx.cwd, ancestor, true)) |_| break else |_| {}
                ancestor = std.fs.path.dirname(ancestor) orelse "/";
            }
            var zb: [sys.path_max:0]u8 = undefined;
            const acc_err: ?linux.E = if (sys.z(&zb, ancestor)) |zp| blk: {
                const err = linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0));
                break :blk if (err == .SUCCESS) null else err;
            } else |_| .NAMETOOLONG;
            if (acc_err) |ae| {
                note(a, &out, lines_ptr, "FAIL", "installation prefix {s} cannot be created under {s} ({s})", .{ p.prefix, ancestor, sys.describeErrno(ae) });
                failed = true;
            } else if (prefixCapacity(c, ancestor)) |cap| {
                if (cap.bytes == 0 or cap.inodes == 0) {
                    note(a, &out, lines_ptr, "FAIL", "installation prefix {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ p.prefix, cap.bytes, cap.inodes });
                    failed = true;
                } else note(a, &out, lines_ptr, "info", "{s} does not exist yet; the first build creates it", .{p.prefix});
            } else note(a, &out, lines_ptr, "info", "{s} does not exist yet; the first build creates it", .{p.prefix});
        }
    }

    // What this shell carries.
    var leftovers: usize = 0;
    for (install_vars) |v| if (c.env.get(v)) |val| {
        if (ownInstallVar(c, s, p, v, val)) |why| {
            note(a, &out, lines_ptr, "ok  ", "{s} {s}", .{ v, why });
            continue;
        }
        leftovers += 1;
        note(a, &out, lines_ptr, "warn", "{s}={s} is set in this shell; eb-local builds clear it, but EESSI-extend or eb run by hand would use it", .{ v, val });
    };
    if (leftovers == 0) note(a, &out, lines_ptr, "ok  ", "no other EESSI or EasyBuild install variable is set in this shell", .{});

    // What eb-local eb needs: the EESSI init, and at most one install variable.
    const eb_stop = if (site) "warn" else "FAIL";
    const init = extend.initPath(a, c.env) catch oom();
    if (fsx.statAt(fsx.cwd, init, true)) |st| {
        if (!st.isReg()) {
            note(a, &out, lines_ptr, eb_stop, "{s} is not a regular file, so `eb-local eb` stops; set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere", .{init});
            if (!site) failed = true;
        } else if (!readable(init)) {
            note(a, &out, lines_ptr, eb_stop, "{s} cannot be read, so `eb-local eb` stops; set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere", .{init});
            if (!site) failed = true;
        } else {
            note(a, &out, lines_ptr, "ok  ", "`eb-local eb` sources {s}", .{init});
        }
    } else |_| {
        note(a, &out, lines_ptr, eb_stop, "{s} is missing, so `eb-local eb` stops; set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere", .{init});
        if (!site) failed = true;
    }
    if (extend.select(c.env)) |sel| {
        const name = extend.variable(sel.mode);
        if (c.env.get(name)) |v| {
            // `eb-local eb` creates a user prefix, but EESSI-extend refuses
            // to load for a project directory that is not there.
            if (sel.mode == .project and !isDir(v)) {
                note(a, &out, lines_ptr, eb_stop, "EESSI_PROJECT_INSTALL={s} is not a directory, so EESSI-extend refuses to load and `eb-local eb` stops; the project owner creates it with the project group and chmod 2770", .{q(a, v)});
                if (!site) failed = true;
            } else note(a, &out, lines_ptr, "ok  ", "`eb-local eb` makes a {s} install: {s}={s}", .{ @tagName(sel.mode), name, q(a, v) });
        } else note(a, &out, lines_ptr, "ok  ", "`eb-local eb` makes a user install into the module's default, $HOME/eessi", .{});
    } else |_| {
        note(a, &out, lines_ptr, eb_stop, "more than one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL, EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL is set, so `eb-local eb` refuses to run", .{});
        if (!site) failed = true;
    }
    for ([_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT" }) |v| if (nonEmpty(c.env.get(v))) |value| {
        if (std.mem.eql(u8, v, "LD_PRELOAD") and onlyXalt(value))
            note(a, &out, lines_ptr, "info", "LD_PRELOAD loads only XALT's libxalt_init.so, the site's usage tracker; builds leave it out", .{})
        else
            note(a, &out, lines_ptr, "warn", "{s} is set; programs built with eb-local dev do not need it, and it can mix host libraries into EESSI's", .{v});
    };
    reportForeign(c, s, p.prefix, &out, lines_ptr);

    // The allocation.
    if (nonEmpty(c.env.get("SLURM_JOB_ID"))) |job| {
        if (s.node_local_root.value.len > 0) {
            var r: storage.Refusal = .{};
            if (storage.jobRoot(a, nodeLocal(s), job, userName(c, s, "doctor checks no further"), mountinfoText(c), callerUid(c), &r)) |jr| {
                note(a, &out, lines_ptr, "ok  ", "Slurm job {s}: build space {s}", .{ job, jr.path });
            } else |e| switch (e) {
                error.Refused => {
                    note(a, &out, lines_ptr, "FAIL", "Slurm job {s}: {s}; builds refuse it. {s}", .{ job, r.message, r.fix });
                    failed = true;
                },
                error.OutOfMemory => oom(),
            }
        }
    } else {
        note(a, &out, lines_ptr, "info", "not in a Slurm job; builds need one on the node type that will run the software{s}{s}", .{ if (s.allocation_hint.value.len > 0) ", for example: " else "", s.allocation_hint.value });
    }

    // Modules and the stack.
    if (nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR"))) |sub| {
        note(a, &out, lines_ptr, "ok  ", "EESSI {s} is loaded for {s}", .{ c.env.get("EESSI_VERSION") orelse "?", sub });
    } else note(a, &out, lines_ptr, "info", "EESSI is not loaded in this shell; eval \"$(eb-local env)\" loads it with your modules", .{});
    noteGuard(c, &out, lines_ptr);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |_| {
        const mp = c.env.get("MODULEPATH") orelse "";
        var seen = false;
        var it = std.mem.splitScalar(u8, mp, ':');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            const resolved = storage.canonical(a, d, c.cwd) catch d;
            if (storage.under(resolved, p.prefix)) {
                seen = true;
                break;
            }
        }
        if (seen) note(a, &out, lines_ptr, "ok  ", "your modules are on MODULEPATH", .{}) else note(a, &out, lines_ptr, "warn", "your modules are not on MODULEPATH in this shell; eval \"$(eb-local env)\"", .{});
    } else |_| {}
    if (nonEmpty(c.env.get("LMOD_CMD")) == null and nonEmpty(c.env.get("MODULESHOME")) == null) {
        const inits = lmodInits(a, c.env);
        for (inits) |file| {
            if (readable(file)) {
                note(a, &out, lines_ptr, "info", "no module command in this shell; builds, env and dev source {s}", .{file});
                break;
            }
        } else {
            note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "no module command in this shell, and none of {s}, {s} or {s} can be read; builds stop there, and the module commands env and dev print do not run", .{ inits[0], inits[1], inits[2] });
            if (site) failed = true;
        }
    } else if (!onModulePath(a, c.env.get("MODULEPATH") orelse "", s.stack_module.value)) {
        // A build keeps the shell's module command, and with it MODULEPATH,
        // and sources no init that would put EESSI's modules there.
        const repo = nonEmpty(c.env.get("EESSI_CVMFS_REPO")) orelse "/cvmfs/software.eessi.io";
        note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "no directory on MODULEPATH in this shell holds stack.module, {s} [{s}], so builds, env and dev cannot load it; module use {s}/init/modules adds EESSI's module directory", .{ s.stack_module.value, s.stack_module.from, repo });
        if (site) failed = true;
    }
    if (proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null) |_| {
        note(a, &out, lines_ptr, "ok  ", "rtrash is on PATH: clean and uninstall move files to the trash", .{});
    } else note(a, &out, lines_ptr, "warn", "rtrash is not on PATH: clean and uninstall remove nothing unless given --delete", .{});

    if (opts.cvmfs) {
        const tasks = opts.parallel orelse s.cvmfs_parallel.value;
        if (reportCvmfs(c, tasks, &out, lines_ptr)) failed = true;
    }
    if (opts.mpi) reportMpi(c, s, &out, lines_ptr);
    if (opts.workspace) |workspace| {
        if (reportWorkspace(c, s, workspace, &out, lines_ptr)) failed = true;
    }

    const warned = hasDoctorWarning(out.items, json_lines.items, g.json_out);
    const strict_fail = opts.strict and warned;
    const any_failed = failed or strict_fail;
    const summary = if (failed)
        (if (site) "Something above says FAIL; builds stop there." else "Something above says FAIL; `eb-local eb` stops there, and `eb-local RECIPE` needs a site file.")
    else if (strict_fail)
        "Something above says warn (--strict); warnings fail under --strict."
    else if (site)
        "Nothing above stops a build."
    else
        "Nothing above stops `eb-local eb`; `eb-local RECIPE` needs a site file.";
    if (g.json_out) {
        jsonout.emit(a, DoctorReport{
            .site_file = site,
            .failed = any_failed,
            .lines = json_lines.items,
            .summary = summary,
        });
        return if (any_failed) 1 else 0;
    }
    out.appendSlice(a, "\n") catch oom();
    out.appendSlice(a, summary) catch oom();
    out.appendSlice(a, "\n") catch oom();
    cli.put(1, out.items);
    return if (any_failed) 1 else 0;
}

// ---- submit ---------------------------------------------------------------

const SubmitOpts = struct {
    /// Comma-separated target names; empty means every configured target.
    on: []const u8 = "",
    /// Print the scripts and sbatch commands; create and submit nothing.
    print: bool = false,
};

/// A job name part: letters, digits, '.', '-' and '_' kept, the rest '_'.
fn jobNamePart(a: Allocator, s: []const u8) []const u8 {
    const out = a.dupe(u8, s[0..@min(s.len, 64)]) catch oom();
    for (out) |*ch| if (!(std.ascii.isAlphanumeric(ch.*) or ch.* == '.' or ch.* == '-' or ch.* == '_')) {
        ch.* = '_';
    };
    return out;
}

fn qSingleLine(a: Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, s, "\n\r") == null) return q(a, s);
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "$'") catch oom();
    for (s) |ch| switch (ch) {
        '\\' => out.appendSlice(a, "\\\\") catch oom(),
        '\'' => out.appendSlice(a, "\\'") catch oom(),
        '\n' => out.appendSlice(a, "\\n") catch oom(),
        '\r' => out.appendSlice(a, "\\r") catch oom(),
        '\t' => out.appendSlice(a, "\\t") catch oom(),
        0...8, 11...12, 14...31, 127 => out.print(a, "\\x{x:0>2}", .{ch}) catch oom(),
        else => out.append(a, ch) catch oom(),
    };
    out.append(a, '\'') catch oom();
    return out.items;
}

/// The command a batch job runs to build: this program, the options that
/// chose this configuration, and the recipe with its eb options as given.
fn jobCommand(c: Ctx, s: config.Settings, g: Global, p: Place, args: []const []const u8) []const u8 {
    const a = c.a;
    var self_buf: [sys.path_max]u8 = undefined;
    const self = selfExe(&self_buf) orelse die("cannot find this program's own path", .{});
    var line: std.ArrayList([]const u8) = .empty;
    line.appendSlice(a, &.{ "exec", qSingleLine(a, self) }) catch oom();
    if (g.config_file) |f| line.appendSlice(a, &.{ "--config", qSingleLine(a, storage.canonical(a, f, c.cwd) catch oom()) }) catch oom();
    if (s.profile) |pr| line.appendSlice(a, &.{ "--profile", qSingleLine(a, pr) }) catch oom();
    if (p.project) line.appendSlice(a, &.{ "--project", qSingleLine(a, p.prefix) }) catch oom();
    for (args) |x| line.append(a, qSingleLine(a, x)) catch oom();
    return std.mem.join(a, " ", line.items) catch oom();
}

/// An sbatch line for each node type the site file lists, which runs the
/// build as a batch job there. The job runs, and writes its output as
/// JOBNAME-JOBID.out, in the directory eb-local runs in, as a job of submit
/// runs there.
fn batchLines(c: Ctx, s: config.Settings, g: Global, p: Place, args: []const []const u8) []const []const u8 {
    const a = c.a;
    const types = nodeTypes(s);
    if (types.len == 0) return &.{};
    const wrap = qSingleLine(a, jobCommand(c, s, g, p, args));
    const recipe = jobNamePart(a, std.fs.path.basename(args[0]));
    var lines: std.ArrayList([]const u8) = .empty;
    const dir = qSingleLine(a, c.cwd);
    for (types) |t| lines.append(a, str(a, "sbatch {s} --job-name=eb-local-{s}-{s} --chdir={s} --output=%x-%j.out --wrap={s}", .{ t.sbatch, t.name, recipe, dir, wrap })) catch oom();
    return lines.items;
}

/// The node types the site file lists, with a warning where it lists them
/// under their old name.
fn nodeTypes(s: config.Settings) []const config.NodeType {
    if (s.node_types_old_key) |where|
        warn("{s}: [build.targets] is now [build.node_types]; eb-local reads the old name until 4.0.0", .{where});
    return s.node_types.value;
}

fn sbatchValue(a: Allocator, v: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, v, " \t\n\r\"\\") == null) return v;
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '"') catch oom();
    for (v) |ch| switch (ch) {
        '"', '\\' => {
            out.append(a, '\\') catch oom();
            out.append(a, ch) catch oom();
        },
        else => out.append(a, ch) catch oom(),
    };
    out.append(a, '"') catch oom();
    return out.items;
}

/// One batch job per configured node type, each running this eb-local with
/// the same recipe, options and configuration inside its own allocation, so
/// a module is built for every CPU target the site has.
fn cmdSubmit(c: Ctx, s: config.Settings, g: Global, args: []const []const u8, o: SubmitOpts) u8 {
    const a = c.a;
    warn("submit is deprecated and is removed in 4.0.0; eb-local --explain RECIPE prints an sbatch line for each node type", .{});
    if (args.len == 0) die("submit needs an easyconfig: eb-local submit [--on NAME,...] [--print] RECIPE [eb options]", .{});
    const all = nodeTypes(s);
    if (all.len == 0) die("no build.node_types in the site file, so there is nothing to submit to; build inside an allocation with eb-local RECIPE", .{});
    var chosen: std.ArrayList(config.NodeType) = .empty;
    if (o.on.len == 0) {
        chosen.appendSlice(a, all) catch oom();
    } else {
        var names = std.mem.splitScalar(u8, o.on, ',');
        while (names.next()) |n| {
            const t = for (all) |cand| {
                if (std.mem.eql(u8, cand.name, n)) break cand;
            } else {
                var known: std.ArrayList([]const u8) = .empty;
                for (all) |k| known.append(a, k.name) catch oom();
                die("--on {s}: no such node type; the site has {s}", .{ n, std.mem.join(a, ", ", known.items) catch oom() });
            };
            for (chosen.items) |already| {
                if (std.mem.eql(u8, already.name, t.name)) break;
            } else chosen.append(a, t) catch oom();
        }
    }
    const p = place(c, s);
    const sbatch = (proc.which(a, "sbatch", c.env.get("PATH") orelse "") catch null) orelse
        if (o.print) "sbatch" else die("sbatch is not on PATH", .{});
    const command = jobCommand(c, s, g, p, args);

    const root = std.fs.path.join(a, &.{ p.prefix, ".eb-local" }) catch oom();
    const jobs = std.fs.path.join(a, &.{ root, "jobs" }) catch oom();
    const logs = std.fs.path.join(a, &.{ root, "logs" }) catch oom();
    if (!o.print) {
        common.atomic.makedirs(jobs) catch |e| die("cannot create {s} ({s})", .{ jobs, storage.describeError(e) });
        common.atomic.makedirs(logs) catch |e| die("cannot create {s} ({s})", .{ logs, storage.describeError(e) });
    }
    const recipe = jobNamePart(a, std.fs.path.basename(args[0]));
    const stamp = nowSecs();
    var failed = false;
    for (chosen.items) |t| {
        const log_out = sbatchValue(a, str(a, "{s}/submit-{s}-%j.out", .{ logs, t.name }));
        const chdir_val = sbatchValue(a, c.cwd);
        const script = str(a,
            \\#!/bin/bash
            \\#SBATCH --job-name=eb-local-{s}-{s}
            \\#SBATCH --output={s}
            \\#SBATCH --chdir={s}
            \\{s}
            \\
        , .{ t.name, recipe, log_out, chdir_val, command });
        const path = std.fs.path.join(a, &.{ jobs, str(a, "{d}-{s}-{s}.sh", .{ stamp, t.name, recipe }) }) catch oom();
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(a, sbatch) catch oom();
        var words = std.mem.tokenizeScalar(u8, t.sbatch, ' ');
        while (words.next()) |w| argv.append(a, w) catch oom();
        argv.append(a, path) catch oom();
        if (o.print) {
            say("# {s}: {s}", .{ t.name, std.mem.join(a, " ", argv.items) catch oom() });
            cli.put(1, script);
            continue;
        }
        var why: common.atomic.Why = .{};
        defer why.deinit(a);
        common.atomic.atomicWrite(a, path, script, .{ .mode = 0o700 }, &why) catch |e|
            die("cannot write {s}: {s}", .{ path, if (why.msg.len > 0) why.msg else common.atomic.describe(e) });
        say("eb-local: {s}:", .{t.name});
        const run = runAttached(a, argv.items, c.envp);
        switch (run) {
            .exit => |code| if (code != 0) {
                warn("sbatch refused the {s} job (exit {d})", .{ t.name, code });
                failed = true;
            },
            .signal => return stop(run),
        }
    }
    if (o.print) return 0;
    say("", .{});
    say("eb-local: each job writes {s}/submit-TARGET-JOBID.out; eb-local list shows the result per target.", .{logs});
    return if (failed) 1 else 0;
}

// ---- uninstall ------------------------------------------------------------

const UninstallOpts = struct {
    dry_run: bool = false,
    delete: bool = false,
    /// A usage log `eb-keep-logs used` reads. Null leaves uninstall as it was.
    usage_log: ?[]const u8 = null,
    /// Limit removal and dependent checks to CPU target trees matching this name.
    target: ?[]const u8 = null,
};

fn matchesTarget(tree: []const u8, wanted: ?[]const u8) bool {
    const raw = wanted orelse return true;
    const w = std.mem.trimEnd(u8, raw, "/");
    const t = treeTarget(tree);
    if (std.mem.indexOfScalar(u8, w, '/') != null) return std.mem.eql(u8, t, w);
    return std.mem.eql(u8, std.fs.path.basename(t), w);
}

test "matchesTarget accepts null, full target paths, and short target names" {
    const tree = "/prefix/versions/2026.06/software/linux/x86_64/amd/zen4";
    try std.testing.expect(matchesTarget(tree, null));
    try std.testing.expect(matchesTarget(tree, "x86_64/amd/zen4"));
    try std.testing.expect(matchesTarget(tree, "x86_64/amd/zen4/"));
    try std.testing.expect(matchesTarget(tree, "zen4"));
    try std.testing.expect(!matchesTarget(tree, "zen2"));
    try std.testing.expect(!matchesTarget(tree, "x86_64/amd/zen2"));
    try std.testing.expect(!matchesTarget(tree, "/"));
}

const Found = struct {
    installs: std.ArrayList([]const u8) = .empty,
    modules: std.ArrayList([]const u8) = .empty,
};

fn isDirAt(dir: sys.fd_t, name: []const u8) bool {
    const st = fsx.statAt(dir, name, false) catch return false;
    return st.isDir();
}

/// The path names itself: no component is a symbolic link.
fn literalPath(c: Ctx, path: []const u8) bool {
    var buf: [sys.path_max]u8 = undefined;
    const real = fsx.realpath(fsx.cwd, path, &buf) catch return false;
    _ = c;
    return std.mem.eql(u8, real, path);
}

/// Below `path`, never through a symbolic link, the target roots (a
/// directory holding both software/ and modules/, one per CPU target as
/// EESSI-extend lays them out), and in each, software/NAME/VERSION,
/// modules/all/NAME/VERSION.lua and the links to it from the other
/// modules/ directories. Installed software is never searched.
fn findInstalls(c: Ctx, path: []const u8, name: []const u8, ver: []const u8, target: ?[]const u8, found: *Found, depth: usize) void {
    if (depth > 12) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    if (isDirAt(fd, "software") and isDirAt(fd, "modules")) {
        if (!matchesTarget(path, target)) return;
        const dir = std.fs.path.join(c.a, &.{ path, "software", name, ver }) catch oom();
        if (fsx.statAt(fsx.cwd, dir, false)) |st| {
            if (st.isDir() and literalPath(c, dir)) found.installs.append(c.a, dir) catch oom();
        } else |_| {}
        const file = std.fs.path.join(c.a, &.{ path, "modules", "all", name, str(c.a, "{s}.lua", .{ver}) }) catch oom();
        if (fsx.statAt(fsx.cwd, file, false)) |st| {
            if (st.isReg() and literalPath(c, file)) found.modules.append(c.a, file) catch oom();
        } else |_| {}
        findClassLinks(c, path, name, ver, file, found);
        return;
    }
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (!st.isDir()) continue;
        findInstalls(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), name, ver, target, found, depth + 1);
    }
}

/// EasyBuild links modules/<class>/NAME/VERSION.lua to `file`, the module
/// file in modules/all, by its absolute path. A link whose target names
/// `file`, or that leads to it, goes with it, and so does one an earlier
/// uninstall left dangling; a link to anything else stays.
fn findClassLinks(c: Ctx, root: []const u8, name: []const u8, ver: []const u8, file: []const u8, found: *Found) void {
    const modules = std.fs.path.join(c.a, &.{ root, "modules" }) catch oom();
    const fd = fsx.openDir(fsx.cwd, modules, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        if (std.mem.eql(u8, e.name, "all") or !isDirAt(fd, e.name)) continue;
        const parent = std.fs.path.join(c.a, &.{ modules, e.name, name }) catch oom();
        const link = std.fs.path.join(c.a, &.{ parent, str(c.a, "{s}.lua", .{ver}) }) catch oom();
        const st = fsx.statAt(fsx.cwd, link, false) catch continue;
        if (!st.isLink() or !literalPath(c, parent)) continue;
        var zb: [sys.path_max:0]u8 = undefined;
        var buf: [sys.path_max]u8 = undefined;
        const n: isize = @bitCast(linux.readlinkat(linux.AT.FDCWD, (sys.z(&zb, link) catch continue).ptr, &buf, buf.len));
        if (n <= 0 or n >= buf.len) continue;
        const named = std.fs.path.resolveAllocPosix(c.a, &.{ parent, buf[0..@intCast(n)] }) catch oom();
        var real: [sys.path_max]u8 = undefined;
        const leads = fsx.realpath(fsx.cwd, link, &real) catch "";
        if (std.mem.eql(u8, named, file) or std.mem.eql(u8, leads, file)) found.modules.append(c.a, link) catch oom();
    }
}

/// Below `path`, in each target root's modules/all, the module files that
/// load one of `wanted` (NAME/VERSION), other than those in `skip`. A file
/// reached through a symbolic link is not read.
fn findDependents(c: Ctx, path: []const u8, wanted: []const []const u8, skip: []const []const u8, target: ?[]const u8, out: *std.ArrayList([]const u8), depth: usize) void {
    if (depth > 12) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    if (isDirAt(fd, "software") and isDirAt(fd, "modules")) {
        if (!matchesTarget(path, target)) return;
        const all = std.fs.path.join(c.a, &.{ path, "modules", "all" }) catch oom();
        const afd = fsx.openDir(fsx.cwd, all, false) catch return;
        defer sys.close(afd);
        var names = fsx.DirIter.init(c.a, afd) catch return;
        while (names.next() catch null) |n| {
            const name = c.a.dupe(u8, n.name) catch oom();
            const nfd = fsx.openDir(afd, name, false) catch continue;
            defer sys.close(nfd);
            var files = fsx.DirIter.init(c.a, nfd) catch continue;
            while (files.next() catch null) |f| {
                if (!std.mem.endsWith(u8, f.name, ".lua")) continue;
                const file = std.fs.path.join(c.a, &.{ all, name, f.name }) catch oom();
                if (listed(skip, file)) continue;
                const opened = fsx.openRegular(nfd, f.name, false) catch continue;
                defer sys.close(opened.fd);
                const text = fsx.readAll(c.a, opened.fd, 1 << 20) catch continue;
                if (loadsAny(text, wanted)) out.append(c.a, file) catch oom();
            }
        }
        return;
    }
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (!st.isDir()) continue;
        findDependents(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), wanted, skip, target, out, depth + 1);
    }
}

fn listed(xs: []const []const u8, x: []const u8) bool {
    for (xs) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// Whether a Lua module file loads one of `wanted`. EasyBuild writes a
/// dependency as depends_on("NAME/VERSION") or, guarded by isloaded,
/// load("NAME/VERSION"), one call to a line.
fn loadsAny(text: []const u8, wanted: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        for ([_][]const u8{ "depends_on(", "load(" }) |call| {
            if (!std.mem.startsWith(u8, line, call)) continue;
            const after = line[call.len..];
            if (after.len < 2 or (after[0] != '"' and after[0] != '\'')) continue;
            const quote = after[0];
            const rest = after[1..];
            const end = std.mem.indexOfScalar(u8, rest, quote) orelse continue;
            if (listed(wanted, rest[0..end])) return true;
        }
    }
    return false;
}

test "loadsAny reads the dependency lines EasyBuild writes" {
    const lua =
        \\help([==[ load("GSL/2.8-GCC-15.2.0") in the help text ]==])
        \\depends_on("FFTW/3.3.10-GCC-15.2.0")
        \\if not ( isloaded("pigz/2.8-GCCcore-15.2.0") ) then
        \\    load("pigz/2.8-GCCcore-15.2.0")
        \\end
    ;
    try std.testing.expect(loadsAny(lua, &.{"FFTW/3.3.10-GCC-15.2.0"}));
    try std.testing.expect(loadsAny(lua, &.{"pigz/2.8-GCCcore-15.2.0"}));
    try std.testing.expect(!loadsAny(lua, &.{"GSL/2.8-GCC-15.2.0"}));
    try std.testing.expect(!loadsAny(lua, &.{"FFTW/3.3.10"}));
}

/// EasyBuild installs are read-only; the owner may make them writable again.
/// Only the directories, which rtrash needs writable to move a directory
/// and to empty the trash; the files keep their read-only modes, in the
/// trash too.
fn makeWritable(c: Ctx, path: []const u8, depth: usize) void {
    if (depth > 64) return;
    const st = fsx.statAt(fsx.cwd, path, false) catch return;
    if (!st.isDir() or st.uid != linux.getuid()) return;
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return;
    _ = linux.fchmodat(linux.AT.FDCWD, zp.ptr, @intCast((st.mode & 0o7777) | 0o200));
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| makeWritable(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), depth + 1);
}

/// Takes write permission from everyone, as EasyBuild does to an
/// installation (EESSI-extend sets EASYBUILD_READ_ONLY_INSTALLDIR); a
/// symbolic link is not followed.
/// Why clean or uninstall removed nothing without --delete: clean.trash
/// is none, or it is auto and rtrash is not on PATH.
fn notTrashed(s: config.Settings) void {
    if (s.trash.value == .none) {
        warn("clean.trash is none [{s}]; nothing removed. Pass --delete to delete for good, or set clean.trash to auto or rtrash.", .{s.trash.from});
    } else warn("rtrash is not installed; nothing removed. Install rtrash, or pass --delete to delete for good.", .{});
}

fn makeReadOnly(c: Ctx, path: []const u8, depth: usize) void {
    if (depth > 64) return;
    const st = fsx.statAt(fsx.cwd, path, false) catch return;
    if (st.isLink() or st.uid != linux.getuid()) return;
    if (st.isDir()) {
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(c.a, fd) catch return;
        while (it.next() catch null) |e| makeReadOnly(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), depth + 1);
    }
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return;
    _ = linux.fchmodat(linux.AT.FDCWD, zp.ptr, @intCast(st.mode & 0o7555));
}

fn cmdUninstall(c: Ctx, s: config.Settings, modules: []const []const u8, o: UninstallOpts) u8 {
    const a = c.a;
    if (modules.len == 0) die("uninstall needs NAME/VERSION, as module avail shows it", .{});
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |st| {
        if (st.isLink() or !literalPath(c, versions)) die("{s} is reached through a symbolic link; uninstall leaves it alone.", .{versions});
    } else |_| die("nothing is installed in {s}", .{p.prefix});
    var prefix_lock: ?sys.fd_t = if (o.dry_run) null else acquirePrefixLock(c, p.prefix);
    defer storage.releaseLock(&prefix_lock);
    if (o.target) |raw_target| {
        const trimmed = std.mem.trimEnd(u8, raw_target, "/");
        if (std.mem.indexOfScalar(u8, trimmed, '/') == null) {
            var trees: std.ArrayList([]const u8) = .empty;
            findTrees(c, versions, &trees, 0);
            std.mem.sort([]const u8, trees.items, {}, lessThanStr);
            var matched: std.ArrayList([]const u8) = .empty;
            for (trees.items) |tree| {
                if (matchesTarget(tree, trimmed)) matched.append(a, tree) catch oom();
            }
            if (matched.items.len > 1) {
                die("--target '{s}' matches more than one CPU tree: {s}; pass the full target", .{
                    raw_target,
                    std.mem.join(a, ", ", matched.items) catch oom(),
                });
            }
        }
    }
    var found: Found = .{};
    for (modules, 0..) |m, idx| {
        if (listed(modules[0..idx], m)) continue;
        var parts = std.mem.splitScalar(u8, m, '/');
        const name = parts.next().?;
        const ver = parts.next() orelse die("uninstall needs NAME/VERSION; '{s}' has no version", .{m});
        if (parts.next() != null) die("uninstall needs NAME/VERSION; '{s}' has more parts", .{m});
        const before = found.installs.items.len + found.modules.items.len;
        findInstalls(c, versions, name, ver, o.target, &found, 0);
        if (found.installs.items.len + found.modules.items.len == before) {
            if (o.target) |t| die("{s} is not installed for target {s} in {s}", .{ m, t, p.prefix });
            die("{s} is not installed in {s}", .{ m, p.prefix });
        }
    }
    // A module another installed module loads stays, unless that one goes
    // in the same command; Lmod would otherwise fail to load the dependent.
    var dependents: std.ArrayList([]const u8) = .empty;
    findDependents(c, versions, modules, found.modules.items, o.target, &dependents, 0);
    if (dependents.items.len > 0) {
        warn("these installed modules load what you named; uninstall them in the same command, or keep it:", .{});
        for (dependents.items) |f| warn("  {s}", .{f});
        return 2;
    }
    // The usage log is eb-keep-logs' to read. Exit 2 from
    // `used --require-none` means the prefix is named there, or the log
    // could not be read; either way nothing is removed. Without the
    // option this is not consulted.
    if (o.usage_log) |log| if (usageRefuses(c, p.prefix, log)) return 2;
    for (found.installs.items) |d| {
        if (!storage.under(d, versions)) die("{s} is outside {s}", .{ d, versions });
        say("  {s}/", .{d});
    }
    for (found.modules.items) |f| say("  {s}", .{f});
    if (o.dry_run) {
        say("eb-local: dry run, nothing removed", .{});
        return 0;
    }
    var trash = s.trash.value;
    const rtrash = proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null;
    switch (trash) {
        .auto => trash = if (rtrash != null) .rtrash else .none,
        .rtrash => if (rtrash == null) die("clean.trash is rtrash, but rtrash is not on PATH.", .{}),
        .none => {},
    }
    if (trash != .rtrash and !o.delete) {
        notTrashed(s);
        return 1;
    }
    for (found.installs.items) |d| makeWritable(c, d, 0);
    if (trash == .rtrash) {
        // rtrash put follows rm(1): a directory needs -r. The installations
        // go first, so a refusal leaves every module file in place.
        for ([_][]const []const u8{ found.installs.items, found.modules.items }) |list| {
            if (list.len == 0) continue;
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(a, &.{ rtrash.?, "put", "-r", "--" }) catch oom();
            argv.appendSlice(a, list) catch oom();
            const run = runAttached(a, argv.items, c.envp);
            switch (run) {
                .exit => |rc| if (rc != 0) die("rtrash put exited {d}; nothing after it was moved", .{rc}),
                .signal => {
                    storage.releaseLock(&prefix_lock);
                    return stop(run);
                },
            }
        }
        say("eb-local: moved {d} installation(s) and {d} module file(s) to the trash (eb-local restore brings them back)", .{ found.installs.items.len, found.modules.items.len });
    } else {
        for (found.installs.items) |d| fsx.deleteTree(a, fsx.cwd, d) catch |e| die("cannot remove {s} ({s})", .{ d, storage.describeError(e) });
        for (found.modules.items) |f| sys.unlinkat(fsx.cwd, f, 0) catch |e| die("cannot remove {s} ({s})", .{ f, storage.describeError(e) });
        say("eb-local: deleted {d} installation(s) and {d} module file(s)", .{ found.installs.items.len, found.modules.items.len });
    }
    // The NAME directories they leave empty.
    for ([_][]const []const u8{ found.installs.items, found.modules.items }) |list| for (list) |x| {
        const parent = std.fs.path.dirname(x) orelse continue;
        sys.unlinkat(fsx.cwd, parent, linux.AT.REMOVEDIR) catch {};
    };
    return 0;
}

/// Relay lines `eb-keep-logs` wrote, without interpreting them.
fn relayChild(text: []const u8) void {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\n"), '\n');
    while (lines.next()) |line| if (line.len > 0) cli.err("  {s}\n", .{line});
}

/// True when uninstall must stop: `eb-keep-logs used --prefix PREFIX
/// --require-none FILE` is missing, cannot be run, or exits non-zero.
/// Exit 2 is the refusal that command documents.
fn usageRefuses(c: Ctx, prefix: []const u8, log: []const u8) bool {
    const bin = (proc.which(c.a, "eb-keep-logs", c.env.get("PATH") orelse "") catch oom()) orelse {
        warn("eb-keep-logs is not on PATH, so the usage log cannot be read; nothing was removed.", .{});
        return true;
    };
    const r = proc.run(c.a, bin, &.{ bin, "used", "--prefix", prefix, "--require-none", log }, c.envp, .{
        .stdout_limit = 1 << 20,
        .stderr_limit = 64 << 10,
        .timeout_ms = 120_000,
    }) catch |e| {
        warn("cannot run eb-keep-logs ({s}); nothing was removed.", .{@errorName(e)});
        return true;
    };
    defer r.deinit(c.a);
    if (r.term.code() == 0) return false;
    if (r.term.code() == 2) {
        warn("eb-keep-logs used --prefix {s} --require-none exited 2; nothing was removed.", .{prefix});
    } else {
        warn("eb-keep-logs used exited {d}; nothing was removed.", .{r.term.code()});
    }
    relayChild(r.stderr);
    relayChild(r.stdout);
    return true;
}

// ---- restore --------------------------------------------------------------

/// An entry of `rtrash list --json`.
const Trashed = struct { original: []const u8, trash_dir: []const u8 };

fn trashList(c: Ctx, rtrash: []const u8) []Trashed {
    const r = proc.run(c.a, rtrash, &.{ rtrash, "list", "--json" }, c.envp, .{ .stdout_limit = 64 << 20, .stderr_limit = 4096, .timeout_ms = 120_000 }) catch |e|
        die("cannot run rtrash list ({s})", .{@errorName(e)});
    if (r.term.code() != 0) die("rtrash list --json exited {d}: {s}", .{ r.term.code(), std.mem.trim(u8, r.stderr, " \n") });
    return std.json.parseFromSliceLeaky([]Trashed, c.a, r.stdout, .{ .ignore_unknown_fields = true }) catch
        die("cannot read what rtrash list --json printed", .{});
}

/// A directory holding both software/ and modules/, as findInstalls takes
/// a target root, named without a symbolic link.
fn targetRoot(c: Ctx, path: []const u8) bool {
    if (!literalPath(c, path)) return false;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return false;
    defer sys.close(fd);
    return isDirAt(fd, "software") and isDirAt(fd, "modules");
}

/// Brings back from the trash what uninstall moved there, for every CPU
/// target, and makes each installation read-only again: rtrash restore
/// alone brings one back with the writable directories rtrash needs.
fn cmdRestore(c: Ctx, s: config.Settings, modules: []const []const u8, dry_run: bool) u8 {
    const a = c.a;
    if (modules.len == 0) die("restore needs NAME/VERSION, as uninstall took it", .{});
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |st| {
        if (st.isLink() or !literalPath(c, versions)) die("{s} is reached through a symbolic link; restore leaves it alone.", .{versions});
    } else |_| die("nothing was installed in {s}", .{p.prefix});
    var prefix_lock: ?sys.fd_t = if (dry_run) null else acquirePrefixLock(c, p.prefix);
    defer storage.releaseLock(&prefix_lock);
    const rtrash = (proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null) orelse
        die("restore brings back what uninstall moved to the trash with rtrash, and rtrash is not on PATH.", .{});
    const entries = trashList(c, rtrash);
    // Installations, the module files in modules/all, and EasyBuild's links
    // to them from modules/<class>/, in the order they come back: nothing
    // is back before what it needs.
    var found = [_]std.ArrayList(Trashed){ .empty, .empty, .empty };
    for (modules, 0..) |m, idx| {
        if (listed(modules[0..idx], m)) continue;
        var parts = std.mem.splitScalar(u8, m, '/');
        const name = parts.next().?;
        const ver = parts.next() orelse die("restore needs NAME/VERSION; '{s}' has no version", .{m});
        if (parts.next() != null) die("restore needs NAME/VERSION; '{s}' has more parts", .{m});
        const install_tail = str(a, "/software/{s}/{s}", .{ name, ver });
        const module_tail = str(a, "/{s}/{s}.lua", .{ name, ver });
        const before = found[0].items.len + found[1].items.len + found[2].items.len;
        for (entries) |e| {
            var root: []const u8 = undefined;
            var kind: usize = 0;
            if (std.mem.endsWith(u8, e.original, install_tail)) {
                root = e.original[0 .. e.original.len - install_tail.len];
            } else if (std.mem.endsWith(u8, e.original, module_tail)) {
                const class = e.original[0 .. e.original.len - module_tail.len];
                const dir = std.fs.path.dirname(class) orelse continue;
                if (!std.mem.eql(u8, std.fs.path.basename(dir), "modules")) continue;
                root = std.fs.path.dirname(dir) orelse continue;
                kind = if (std.mem.eql(u8, std.fs.path.basename(class), "all")) 1 else 2;
            } else continue;
            if (storage.under(root, versions) and targetRoot(c, root)) found[kind].append(a, e) catch oom();
        }
        if (found[0].items.len + found[1].items.len + found[2].items.len == before) die("{s} is not in the trash for {s}", .{ m, p.prefix });
    }
    for (found) |list| for (list.items, 0..) |e, i| {
        for (list.items[i + 1 ..]) |o| if (std.mem.eql(u8, e.original, o.original))
            die("{s} is in the trash more than once; restore the one you want with: rtrash restore {s}", .{ e.original, q(a, e.original) });
        if (fsx.statAt(fsx.cwd, e.original, false)) |_| {
            die("{s} exists; restore replaces nothing, so nothing was restored", .{e.original});
        } else |_| {}
    };
    for (found, 0..) |list, kind| for (list.items) |e| say("  {s}{s}", .{ e.original, if (kind == 0) "/" else "" });
    if (dry_run) {
        say("eb-local: dry run, nothing restored", .{});
        return 0;
    }
    // rtrash restore takes no --; every path is absolute.
    for (found, 0..) |list, kind| for (list.items) |e| {
        const run = runAttached(a, &.{ rtrash, "restore", str(a, "--trash-dir={s}", .{e.trash_dir}), e.original }, c.envp);
        switch (run) {
            .exit => |rc| if (rc != 0) die("rtrash restore exited {d}; nothing after {s} was restored", .{ rc, e.original }),
            .signal => {
                storage.releaseLock(&prefix_lock);
                return stop(run);
            },
        }
        if (kind == 0 and literalPath(c, e.original)) makeReadOnly(c, e.original, 0);
    };
    say("eb-local: restored {d} installation(s), read-only again, and {d} module file(s)", .{ found[0].items.len, found[1].items.len + found[2].items.len });
    return 0;
}

// ---- entry ----------------------------------------------------------------

const Command = enum { build, eb, env, dev, clean, config, profiles, uninstall, restore, site, @"rpath-wrappers", check, list, doctor, @"lmod-cache", modulerc, overlay, submit };

/// The command a word names, other than the default build.
fn subcommand(word: []const u8) ?Command {
    const cmd = std.meta.stringToEnum(Command, word) orelse return null;
    return if (cmd == .build) null else cmd;
}

/// Run the command the arguments name, and return its exit status. With
/// `EB_LOCAL_EESSI_EXTEND` set, not empty and not `0`, every argument is
/// eb's, as for `eb-local eb --`.
pub fn main(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    const argv_all = init.minimal.args.toSlice(a) catch die("cannot read the arguments", .{});
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = a.dupe(u8, fsx.realpath(fsx.cwd, ".", &cwd_buf) catch "/") catch oom();
    const c: Ctx = .{ .a = a, .io = init.io, .env = init.environ_map, .envp = init.minimal.environ.block.slice.ptr, .cwd = cwd };
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_SELF_OWNER"))) |v| test_self_owner = std.fmt.parseInt(linux.uid_t, v, 10) catch null;
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_FLOCK_ERRNO"))) |v| {
            if (std.mem.eql(u8, v, "ENOLCK")) {
                storage.test_flock_errno = .NOLCK;
            } else if (std.mem.eql(u8, v, "ENOTSUP") or std.mem.eql(u8, v, "EOPNOTSUPP")) {
                storage.test_flock_errno = .OPNOTSUPP;
            } else if (std.mem.eql(u8, v, "ENOSYS")) {
                storage.test_flock_errno = .NOSYS;
            }
        }
    }
    // A single program name, then eb's own arguments: an eb-stack target.
    if (extend.engaged(c.env)) {
        const raw = argv_all[1..];
        const forwarded = a.alloc([]const u8, raw.len) catch oom();
        for (raw, 0..) |arg, n| forwarded[n] = arg;
        return cmdExtend(c, forwarded);
    }

    var args: []const [:0]const u8 = argv_all[1..];
    var command: Command = .build;
    if (args.len > 0) {
        const first: []const u8 = args[0];
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            cli.put(1, usage_text);
            return 0;
        }
        if (std.mem.eql(u8, first, "--version")) {
            cli.put(1, comptime cli.versionLine(tool, version, build_options.commit));
            return 0;
        }
        if (std.meta.stringToEnum(Command, first)) |cmd| {
            if (cmd != .build) {
                command = cmd;
                args = args[1..];
            }
        } else if (std.mem.eql(u8, first, "--env")) {
            command = .env;
            args = args[1..];
        }
    }

    var g: Global = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    var clean: CleanOpts = .{};
    var uninstall: UninstallOpts = .{};
    var submit: SubmitOpts = .{};
    var check = false;
    var check_quiet = false;
    var check_recursive = false;
    var check_dev = false;
    var check_prefix: ?[]const u8 = null;
    var check_modules: std.ArrayList([]const u8) = .empty;
    var as_env = false;
    var config_get: ?[]const u8 = null;
    var site: SiteOpts = .{};
    var family: []const u8 = "";
    var only_unwrapped = false;
    var cache: lmodcache.Options = .{};
    var module_tree: []const u8 = "";
    var module_defaults: std.ArrayList([]const u8) = .empty;
    var module_aliases: std.ArrayList(modulerc.Alias) = .empty;
    var module_hidden: std.ArrayList([]const u8) = .empty;
    var modulerc_dry_run = false;
    var modulerc_check = false;
    var doctor_strict = false;
    var doctor_cvmfs = false;
    var doctor_parallel: ?u8 = null;
    var doctor_mpi = false;
    var doctor_workspace: ?[]const u8 = null;
    var list_missing = false;
    var overlay_action: []const u8 = "";
    var overlay_materialize: recipe_overlay.MaterializeOptions = .{};
    var overlay_eb_stack: []const u8 = "";
    var overlay_forward: std.ArrayList([]const u8) = .empty;
    var overlay_passthrough = false;
    var i: usize = 0;
    const value = struct {
        fn get(xs: []const [:0]const u8, idx: *usize, opt: []const u8) []const u8 {
            if (idx.* + 1 >= xs.len or xs[idx.* + 1].len == 0) die("{s} needs a value", .{opt});
            idx.* += 1;
            return xs[idx.*];
        }
    }.get;
    const joined = struct {
        /// The value of OPT=VALUE when X is that; empty, as after a space, it is refused.
        fn get(x: []const u8, opt: []const u8) ?[]const u8 {
            if (!std.mem.startsWith(u8, x, opt) or x.len == opt.len or x[opt.len] != '=') return null;
            if (x.len == opt.len + 1) die("{s} needs a value", .{opt});
            return x[opt.len + 1 ..];
        }
    }.get;
    while (i < args.len) : (i += 1) {
        const x: []const u8 = args[i];
        if (command == .eb and std.mem.eql(u8, x, "--")) {
            // eb's own --help, and any option eb-local also knows, is eb's.
            for (args[i..]) |arg| rest.append(a, arg) catch oom();
            break;
        }
        if (command == .overlay and overlay_passthrough) {
            overlay_forward.append(a, x) catch oom();
            continue;
        }
        if (std.mem.eql(u8, x, "-h") or std.mem.eql(u8, x, "--help")) {
            cli.put(1, usage_text);
            return 0;
        } else if (std.mem.eql(u8, x, "--project")) {
            g.project = value(args, &i, "--project");
        } else if (joined(x, "--project")) |v| {
            g.project = v;
        } else if (std.mem.eql(u8, x, "--profile")) {
            g.profile = value(args, &i, "--profile");
        } else if (joined(x, "--profile")) |v| {
            g.profile = v;
        } else if (std.mem.eql(u8, x, "--config")) {
            g.config_file = value(args, &i, "--config");
        } else if (joined(x, "--config")) |v| {
            g.config_file = v;
        } else if (std.mem.eql(u8, x, "--env") and command == .build and rest.items.len == 0) {
            command = .env;
        } else if (std.mem.eql(u8, x, "--explain") and command == .build and rest.items.len == 0) {
            g.explain = true;
        } else if (command == .build and rest.items.len == 0 and subcommand(x) != null) {
            // Global options may come first: eb-local --profile gpu dev.
            command = subcommand(x).?;
        } else switch (command) {
            .build, .eb => rest.append(a, x) catch oom(),
            .@"rpath-wrappers" => {
                if (std.mem.eql(u8, x, "--for") or joined(x, "--for") != null) {
                    family = if (joined(x, "--for")) |v| v else value(args, &i, "--for");
                    for (family) |ch| if (!std.ascii.isAlphanumeric(ch)) die("--for takes a compiler family name", .{});
                } else if (std.mem.eql(u8, x, "--unwrapped")) {
                    only_unwrapped = true;
                } else die("rpath-wrappers takes only --for FAMILY or --unwrapped; got '{s}'", .{x});
            },
            .check => {
                if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else if (std.mem.eql(u8, x, "--quiet")) {
                    check_quiet = true;
                } else if (std.mem.eql(u8, x, "--recursive")) {
                    check_recursive = true;
                } else if (std.mem.eql(u8, x, "--dev")) {
                    check_dev = true;
                } else if (std.mem.eql(u8, x, "--prefix")) {
                    if (check_prefix != null) die("check takes one --prefix", .{});
                    check_prefix = value(args, &i, "--prefix");
                } else if (joined(x, "--prefix")) |v| {
                    if (check_prefix != null) die("check takes one --prefix", .{});
                    check_prefix = v;
                } else if (std.mem.eql(u8, x, "--module")) {
                    check_modules.append(a, value(args, &i, "--module")) catch oom();
                } else if (joined(x, "--module")) |v| {
                    check_modules.append(a, v) catch oom();
                } else if (x.len > 0 and x[0] == '-') {
                    die("check does not know '{s}'", .{x});
                } else if (check_modules.items.len > 0) {
                    check_modules.append(a, x) catch oom();
                } else rest.append(a, x) catch oom();
            },
            .env => {
                if (std.mem.eql(u8, x, "--strict")) {
                    g.env_strict = true;
                } else if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else die("env takes only --project, --profile, --config and --strict; got '{s}'", .{x});
            },
            .profiles => {
                if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else die("profiles takes only --project, --profile, --config and --json; got '{s}'", .{x});
            },
            .doctor => {
                if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else if (std.mem.eql(u8, x, "--strict")) {
                    doctor_strict = true;
                } else if (std.mem.eql(u8, x, "--cvmfs")) {
                    doctor_cvmfs = true;
                } else if (std.mem.eql(u8, x, "--cvmfs-parallel") or joined(x, "--cvmfs-parallel") != null) {
                    const v = if (joined(x, "--cvmfs-parallel")) |got| got else value(args, &i, "--cvmfs-parallel");
                    const n = std.fmt.parseInt(u8, v, 10) catch die("--cvmfs-parallel needs a number from 1 to 8", .{});
                    if (n < 1 or n > 8) die("--cvmfs-parallel needs a number from 1 to 8", .{});
                    doctor_parallel = n;
                    doctor_cvmfs = true;
                } else if (std.mem.eql(u8, x, "--mpi")) {
                    doctor_mpi = true;
                } else if (std.mem.eql(u8, x, "--workspace")) {
                    if (doctor_workspace != null) die("doctor takes one --workspace", .{});
                    doctor_workspace = value(args, &i, "--workspace");
                } else if (joined(x, "--workspace")) |v| {
                    if (doctor_workspace != null) die("doctor takes one --workspace", .{});
                    doctor_workspace = v;
                } else die("doctor takes --json, --strict, --workspace, --cvmfs, --cvmfs-parallel and --mpi; got '{s}'", .{x});
            },
            .@"lmod-cache" => {
                if (std.mem.eql(u8, x, "--modulepath")) {
                    cache.modulepath = value(args, &i, "--modulepath");
                } else if (joined(x, "--modulepath")) |v| {
                    cache.modulepath = v;
                } else if (std.mem.eql(u8, x, "--cache-dir")) {
                    cache.cache_dir = value(args, &i, "--cache-dir");
                } else if (joined(x, "--cache-dir")) |v| {
                    cache.cache_dir = v;
                } else if (std.mem.eql(u8, x, "--timestamp")) {
                    cache.timestamp = value(args, &i, "--timestamp");
                } else if (joined(x, "--timestamp")) |v| {
                    cache.timestamp = v;
                } else if (std.mem.eql(u8, x, "--spider")) {
                    cache.spider = value(args, &i, "--spider");
                } else if (joined(x, "--spider")) |v| {
                    cache.spider = v;
                } else if (std.mem.eql(u8, x, "--prefix")) {
                    cache.prefix = value(args, &i, "--prefix");
                } else if (joined(x, "--prefix")) |v| {
                    cache.prefix = v;
                } else if (std.mem.eql(u8, x, "--eessi-version")) {
                    cache.eessi_version = value(args, &i, "--eessi-version");
                } else if (joined(x, "--eessi-version")) |v| {
                    cache.eessi_version = v;
                } else if (std.mem.eql(u8, x, "--update-cmd")) {
                    cache.update_cmd = value(args, &i, "--update-cmd");
                } else if (joined(x, "--update-cmd")) |v| {
                    cache.update_cmd = v;
                } else if (std.mem.eql(u8, x, "--dry-run")) {
                    cache.dry_run = true;
                } else if (std.mem.eql(u8, x, "--verify")) {
                    cache.verify = true;
                } else die("lmod-cache does not know '{s}'", .{x});
            },
            .modulerc => {
                if (std.mem.eql(u8, x, "--module-tree")) {
                    module_tree = value(args, &i, "--module-tree");
                } else if (joined(x, "--module-tree")) |v| {
                    module_tree = v;
                } else if (std.mem.eql(u8, x, "--default") or joined(x, "--default") != null) {
                    const m = if (joined(x, "--default")) |v| v else value(args, &i, "--default");
                    if (!config.validModule(m)) die("'{s}' is not a module name", .{m});
                    module_defaults.append(a, m) catch oom();
                } else if (std.mem.eql(u8, x, "--alias") or joined(x, "--alias") != null) {
                    const spec = if (joined(x, "--alias")) |v| v else value(args, &i, "--alias");
                    const equal = std.mem.indexOfScalar(u8, spec, '=') orelse die("--alias needs NAME=MODULE", .{});
                    if (equal == 0 or equal + 1 == spec.len) die("--alias needs NAME=MODULE", .{});
                    const alias_name = spec[0..equal];
                    const alias_target = spec[equal + 1 ..];
                    if (!config.validModule(alias_name)) die("'{s}' is not a module name", .{alias_name});
                    if (!config.validModule(alias_target)) die("'{s}' is not a module name", .{alias_target});
                    module_aliases.append(a, .{ .name = alias_name, .target = alias_target }) catch oom();
                } else if (std.mem.eql(u8, x, "--hide") or joined(x, "--hide") != null) {
                    const m = if (joined(x, "--hide")) |v| v else value(args, &i, "--hide");
                    if (!config.validModule(m)) die("'{s}' is not a module name", .{m});
                    module_hidden.append(a, m) catch oom();
                } else if (std.mem.eql(u8, x, "--dry-run")) {
                    modulerc_dry_run = true;
                } else if (std.mem.eql(u8, x, "--check")) {
                    modulerc_check = true;
                } else if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else die("modulerc does not know '{s}'", .{x});
            },
            .overlay => {
                if (std.mem.eql(u8, x, "--")) {
                    overlay_passthrough = true;
                } else if (std.mem.eql(u8, x, "--overlay")) {
                    overlay_materialize.overlay_path = value(args, &i, "--overlay");
                } else if (joined(x, "--overlay")) |v| {
                    overlay_materialize.overlay_path = v;
                } else if (std.mem.eql(u8, x, "--base")) {
                    overlay_materialize.base_path = value(args, &i, "--base");
                } else if (joined(x, "--base")) |v| {
                    overlay_materialize.base_path = v;
                } else if (std.mem.eql(u8, x, "--out-dir")) {
                    overlay_materialize.out_dir = value(args, &i, "--out-dir");
                } else if (joined(x, "--out-dir")) |v| {
                    overlay_materialize.out_dir = v;
                } else if (std.mem.eql(u8, x, "--dry-run")) {
                    overlay_materialize.dry_run = true;
                } else if (std.mem.eql(u8, x, "--check")) {
                    overlay_materialize.check = true;
                } else if (std.mem.eql(u8, x, "--eb-stack")) {
                    overlay_eb_stack = value(args, &i, "--eb-stack");
                } else if (joined(x, "--eb-stack")) |v| {
                    overlay_eb_stack = v;
                } else if (overlay_action.len == 0 and x.len > 0 and x[0] != '-') {
                    overlay_action = x;
                } else if (overlay_action.len == 0 and x.len > 0 and x[0] == '-') {
                    die("overlay does not know '{s}'", .{x});
                } else if (std.mem.eql(u8, x, "materialize") or std.mem.eql(u8, x, "bump") or std.mem.eql(u8, x, "plan")) {
                    die("overlay action must come first: eb-local overlay materialize|bump|plan ...", .{});
                } else {
                    overlay_forward.append(a, x) catch oom();
                }
            },
            .submit => {
                if (rest.items.len == 0 and std.mem.eql(u8, x, "--on")) {
                    submit.on = value(args, &i, "--on");
                } else if (rest.items.len == 0 and joined(x, "--on") != null) {
                    submit.on = joined(x, "--on").?;
                } else if (rest.items.len == 0 and std.mem.eql(u8, x, "--print")) {
                    submit.print = true;
                } else if (rest.items.len == 0 and x.len > 0 and x[0] == '-') {
                    die("submit does not know '{s}'", .{x});
                } else rest.append(a, x) catch oom();
            },
            .list => {
                if (std.mem.eql(u8, x, "--missing")) {
                    list_missing = true;
                } else if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else if (x.len > 0 and x[0] == '-') {
                    die("list does not know '{s}'", .{x});
                } else {
                    if (std.mem.indexOfAny(u8, x, " \t\n;$`\\") != null) die("'{s}' is not a module name", .{x});
                    rest.append(a, x) catch oom();
                }
            },
            .config => {
                if (std.mem.eql(u8, x, "--check")) {
                    check = true;
                } else if (std.mem.eql(u8, x, "--env")) {
                    as_env = true;
                } else if (std.mem.eql(u8, x, "--get")) {
                    if (config_get != null) die("config takes one --get", .{});
                    config_get = value(args, &i, "--get");
                } else if (joined(x, "--get")) |v| {
                    if (config_get != null) die("config takes one --get", .{});
                    config_get = v;
                } else if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else die("config does not know '{s}'", .{x});
                if (@as(usize, @intFromBool(check)) + @intFromBool(as_env) + @intFromBool(config_get != null) > 1)
                    die("config takes --check, --env or --get", .{});
            },
            .site => {
                if (std.mem.eql(u8, x, "--json")) {
                    site.json = true;
                } else if (std.mem.eql(u8, x, "--set") or joined(x, "--set") != null) {
                    var d: sites.Diagnostic = .{};
                    const raw = if (joined(x, "--set")) |v| v else value(args, &i, "--set");
                    const set = sites.parseSet(a, raw, &d) catch |e| switch (e) {
                        error.Invalid => die("{s}", .{d.message}),
                        error.OutOfMemory => oom(),
                    };
                    site.sets.append(a, set) catch oom();
                } else if (std.mem.eql(u8, x, "--to")) {
                    if (site.to != null) die("site takes one --to", .{});
                    site.to = value(args, &i, "--to");
                } else if (joined(x, "--to")) |v| {
                    if (site.to != null) die("site takes one --to", .{});
                    site.to = v;
                } else if (std.mem.eql(u8, x, "--force")) {
                    site.force = true;
                } else if (x.len > 0 and x[0] == '-') {
                    die("site does not know '{s}'", .{x});
                } else site.words.append(a, x) catch oom();
            },
            .dev => {
                if (std.mem.eql(u8, x, "--strict")) {
                    g.env_strict = true;
                } else if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else if (std.mem.eql(u8, x, "--envrc")) {
                    g.envrc = true;
                } else if (std.mem.eql(u8, x, "--buildenv")) {
                    g.buildenv = value(args, &i, "--buildenv");
                } else if (joined(x, "--buildenv")) |v| {
                    g.buildenv = v;
                } else if (x.len > 0 and x[0] == '-') {
                    die("dev does not know the option '{s}'", .{x});
                } else if (!config.validModule(x)) {
                    die("'{s}' is not a module name", .{x});
                } else rest.append(a, x) catch oom();
            },
            .clean => {
                if (std.mem.eql(u8, x, "--logs-older-than") or joined(x, "--logs-older-than") != null) {
                    if (clean.logs_days != null) die("clean takes one --logs-older-than", .{});
                    const v = if (joined(x, "--logs-older-than")) |got| got else value(args, &i, "--logs-older-than");
                    const n = std.fmt.parseInt(u32, v, 10) catch die("--logs-older-than needs a number of days", .{});
                    if (n > 99999) die("--logs-older-than needs a number of days", .{});
                    clean.logs_days = n;
                } else if (std.mem.eql(u8, x, "--no-logs")) {
                    clean.logs = false;
                } else if (std.mem.eql(u8, x, "--sources")) {
                    clean.sources = true;
                } else if (std.mem.eql(u8, x, "--workspaces")) {
                    clean.workspaces = true;
                } else if (std.mem.eql(u8, x, "--dry-run")) {
                    clean.dry_run = true;
                } else if (std.mem.eql(u8, x, "--delete")) {
                    clean.delete = true;
                } else if (std.mem.eql(u8, x, "--json")) {
                    g.json_out = true;
                } else die("clean does not know '{s}'", .{x});
            },
            .uninstall, .restore => {
                if (std.mem.eql(u8, x, "--dry-run")) {
                    uninstall.dry_run = true;
                } else if (command == .uninstall and std.mem.eql(u8, x, "--delete")) {
                    uninstall.delete = true;
                } else if (command == .uninstall and std.mem.eql(u8, x, "--usage-log")) {
                    if (uninstall.usage_log != null) die("uninstall takes one --usage-log", .{});
                    uninstall.usage_log = value(args, &i, "--usage-log");
                } else if (command == .uninstall and joined(x, "--usage-log") != null) {
                    if (uninstall.usage_log != null) die("uninstall takes one --usage-log", .{});
                    uninstall.usage_log = joined(x, "--usage-log").?;
                } else if (command == .uninstall and std.mem.eql(u8, x, "--target")) {
                    if (uninstall.target != null) die("uninstall takes one --target", .{});
                    uninstall.target = value(args, &i, "--target");
                } else if (command == .uninstall and joined(x, "--target") != null) {
                    if (uninstall.target != null) die("uninstall takes one --target", .{});
                    uninstall.target = joined(x, "--target").?;
                } else if (x.len > 0 and x[0] == '-') {
                    die("{s} does not know '{s}'", .{ @tagName(command), x });
                } else if (!config.validModule(x)) {
                    die("'{s}' is not a module name", .{x});
                } else rest.append(a, x) catch oom();
            },
        }
    }

    // --explain promises that nothing runs; a command it does not explain
    // would run as if it were not there.
    if (g.explain and command != .build and command != .eb)
        die("--explain goes with a recipe or with eb, not with {s}", .{@tagName(command)});
    // The cache is a pair of files. It does not read the site file.
    if (command == .@"lmod-cache") return lmodcache.run(init.io, a, c.env, cache);
    if (command == .overlay) {
        if (overlay_action.len == 0) die("overlay takes materialize, bump or plan", .{});
        if (std.mem.eql(u8, overlay_action, "materialize")) {
            if (overlay_forward.items.len > 0) die("overlay materialize does not know '{s}'", .{overlay_forward.items[0]});
            if (overlay_passthrough) die("overlay materialize does not take --", .{});
            if (overlay_eb_stack.len > 0) die("overlay materialize does not take --eb-stack", .{});
            return recipe_overlay.runMaterialize(init.io, a, overlay_materialize);
        }
        if (std.mem.eql(u8, overlay_action, "bump") or std.mem.eql(u8, overlay_action, "plan")) {
            if (overlay_materialize.overlay_path.len > 0 or overlay_materialize.base_path.len > 0 or
                overlay_materialize.out_dir.len > 0 or overlay_materialize.dry_run or overlay_materialize.check)
                die("overlay {s} does not take materialize options", .{overlay_action});
            return cmdOverlayEbStack(c, overlay_action, overlay_eb_stack, overlay_forward.items);
        }
        die("overlay takes materialize, bump or plan; got '{s}'", .{overlay_action});
    }
    // A module tree's control file does not depend on eb-local configuration.
    if (command == .modulerc) {
        if (modulerc_dry_run and modulerc_check) die("modulerc takes --dry-run or --check, not both", .{});
        return modulerc.run(init.io, a, .{
            .tree = module_tree,
            .defaults = module_defaults.items,
            .aliases = module_aliases.items,
            .hidden = module_hidden.items,
            .dry_run = modulerc_dry_run,
            .check = modulerc_check,
            .json = g.json_out,
        });
    }
    if (command == .profiles) return cmdProfiles(c, g);
    // A site file can be written while the configuration in force is broken.
    if (command == .site) {
        const action = if (site.words.items.len > 0) site.words.items[0] else "list";
        if (site.json and !std.mem.eql(u8, action, "list")) die("--json goes with site list, not site {s}", .{action});
        return cmdSite(c, site);
    }
    if (command == .@"rpath-wrappers") {
        if (only_unwrapped and family.len > 0) die("rpath-wrappers takes --for FAMILY or --unwrapped, not both", .{});
        return cmdRpathWrappers(c, family, only_unwrapped);
    }
    if (command == .check) {
        const modes: usize = @as(usize, @intFromBool(check_dev)) + @intFromBool(check_prefix != null) + @intFromBool(check_modules.items.len > 0);
        if (modes > 1 or (modes == 1 and rest.items.len > 0))
            die("check takes files, or one of --module, --dev and --prefix", .{});
        if (modes == 0) return cmdCheck(c, rest.items, check_quiet, g.json_out, check_recursive);
        if (check_prefix) |dir| return cmdCheckTree(c, null, .prefix, &.{}, dir, check_quiet, g.json_out, check_recursive);
        const s = loadSettings(c, g);
        if (check_dev) return cmdCheckTree(c, s, .dev, &.{}, "", check_quiet, g.json_out, check_recursive);
        return cmdCheckTree(c, s, .module, check_modules.items, "", check_quiet, g.json_out, check_recursive);
    }
    // The install mode is the four EESSI variables, not the site file.
    if (command == .eb) {
        if (g.profile != null or g.project != null or g.config_file != null)
            die("eb reads the install mode from the environment, not from --profile, --project or --config", .{});
        return if (g.explain) explainExtend(c, rest.items) else cmdExtend(c, rest.items);
    }
    const s = loadSettings(c, g);
    return switch (command) {
        .env => cmdEnv(c, s, g),
        .dev => cmdDev(c, s, g, rest.items),
        .config => blk: {
            if (as_env and g.json_out) die("config --json does not go with --env", .{});
            if (config_get != null and g.json_out) die("config --json does not go with --get", .{});
            if (config_get) |key| break :blk cmdConfigGet(c, s, key);
            break :blk if (as_env) cmdConfigEnv(c, s) else cmdConfig(c, s, check, g.json_out);
        },
        .clean => blk: {
            if (!clean.logs and clean.logs_days != null) die("clean takes --no-logs or --logs-older-than, not both", .{});
            break :blk cmdClean(c, s, clean, g.json_out);
        },
        .build => cmdBuild(c, s, g, rest.items),
        .uninstall => cmdUninstall(c, s, rest.items, uninstall),
        .restore => cmdRestore(c, s, rest.items, uninstall.dry_run),
        .list => blk: {
            if (list_missing and g.json_out) die("list takes --missing or --json, not both", .{});
            break :blk cmdList(c, s, rest.items, g.json_out, list_missing);
        },
        .doctor => cmdDoctor(c, s, g, .{ .strict = doctor_strict, .cvmfs = doctor_cvmfs, .parallel = doctor_parallel, .mpi = doctor_mpi, .workspace = doctor_workspace }),
        .submit => cmdSubmit(c, s, g, rest.items, submit),
        .eb, .profiles, .site, .@"rpath-wrappers", .check, .@"lmod-cache", .modulerc, .overlay => unreachable,
    };
}

fn cmdOverlayEbStack(c: Ctx, sub: []const u8, eb_stack: []const u8, forward: []const []const u8) u8 {
    const program = if (eb_stack.len > 0) eb_stack else (proc.which(c.a, "eb-stack", c.env.get("PATH") orelse "") catch null) orelse
        die("eb-stack is not on PATH; pass --eb-stack PATH for overlay {s}", .{sub});
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(c.a, program) catch oom();
    argv.append(c.a, "package") catch oom();
    argv.append(c.a, sub) catch oom();
    for (forward) |arg| argv.append(c.a, arg) catch oom();
    return stop(runAttached(c.a, argv.items, c.envp));
}

test {
    _ = toml;
    _ = config;
    _ = secrets;
    _ = sites;
    _ = storage;
    _ = rpath;
    _ = elfcheck;
    _ = extend;
    _ = lmodcache;
    _ = modulerc;
    _ = jsonout;
    _ = foreign;
    _ = cvmfs;
    _ = mpi;
    _ = recipe_overlay;
}

test "a build script selects no MPI transport" {
    try std.testing.expect(std.mem.indexOf(u8, build_script, "OMPI_MCA") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_script, "FI_PROVIDER") == null);
}

fn cmdExtend(c: Ctx, args: []const []const u8) u8 {
    const eb_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
    const sel = extend.select(c.env) catch |err| switch (err) {
        error.TooMany => {
            cli.err("{s}", .{extend.tooMany(c.a, c.env) catch oom()});
            return 3;
        },
    };
    var env = c.env.clone(c.a) catch oom();
    defer env.deinit();
    extend.apply(&env);
    for (shell_startup) |name| _ = env.swapRemove(name);
    const argv = extend.commandLine(c.a, sel, eb_args) catch oom();
    return stop(runAttached(c.a, argv, envpOf(c.a, &env)));
}

/// What eb-local eb would run: the launcher's own script after a `set --`
/// line with the arguments it would get, so the text runs as the launcher
/// does. Nothing runs and nothing is created.
fn explainExtend(c: Ctx, args: []const []const u8) u8 {
    const a = c.a;
    const eb_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
    const sel = extend.select(c.env) catch |err| switch (err) {
        error.TooMany => {
            cli.err("{s}", .{extend.tooMany(a, c.env) catch oom()});
            return 3;
        },
    };
    const argv = extend.commandLine(a, sel, eb_args) catch oom();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "# eb-local --explain eb: the script eb-local eb runs, with its arguments. Nothing was run.\n") catch oom();
    const name = extend.variable(sel.mode);
    if (c.env.get(name)) |v| {
        out.print(a, "# {s}={s} selects a {s} install; the process umask is {s}.\n", .{ name, q(a, v), @tagName(sel.mode), sel.umask }) catch oom();
    } else {
        out.print(a, "# No install variable is set: a user install into the module's default, $HOME/eessi; the process umask is {s}.\n", .{sel.umask}) catch oom();
    }
    out.appendSlice(a, "# It runs in a clean bash (no profile, no rc file):\n#  ") catch oom();
    for (argv[0..4]) |x| out.print(a, " {s}", .{x}) catch oom();
    out.appendSlice(a, " \"$SCRIPT\"") catch oom();
    for (argv[5..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.appendSlice(a, "\n# where SCRIPT is everything after the next line.\nset --") catch oom();
    for (argv[6..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.print(a, "\n{s}\n", .{extend.script}) catch oom();
    cli.put(1, out.items);
    return 0;
}

test "a build has the process umask eb-local eb has for the same install" {
    for ([_]Place{ .{ .prefix = "/x", .project = false }, .{ .prefix = "/x", .project = true } }) |p| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        try env.put(if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", p.prefix);
        const sel = try extend.select(&env);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, sel.umask, 8), buildUmask(p));
    }
}

test "eb is the EESSI-extend command" {
    try std.testing.expectEqual(Command.eb, subcommand("eb").?);
    try std.testing.expect(subcommand("build") == null);
    try std.testing.expect(subcommand("env") != null);
}

test "the replay line repeats the options that selected this environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: config.Settings = .{};
    s.profile = "gpu";
    s.project = .{ .value = "/proj/my group" };
    const g: Global = .{ .config_file = "/etc/x.toml", .buildenv = "buildenv/lfoss" };
    try std.testing.expectEqualStrings("--config /etc/x.toml --profile gpu --project '/proj/my group' dev --buildenv buildenv/lfoss FFTW/1", replay(a, "dev", s, g, "/proj/my group", &.{"FFTW/1"}));
    try std.testing.expectEqualStrings("env", replay(a, "env", .{}, .{}, "/home/u/.local/eessi", &.{}));
}

test "a signal that killed the child kills this process, and an ignored one does not" {
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = stop(.{ .signal = .TERM });
        linux.exit_group(42);
    }
    var raw: i32 = 0;
    while (true) {
        const wr = linux.wait4(@intCast(pid), &raw, 0, null);
        switch (linux.errno(wr)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TestUnexpectedResult,
        }
    }
    const status: u32 = @bitCast(raw);
    try std.testing.expect(linux.W.IFSIGNALED(status));
    try std.testing.expectEqual(linux.SIG.TERM, linux.W.TERMSIG(status));

    const pid2: isize = @bitCast(linux.fork());
    if (pid2 < 0) return error.TestUnexpectedResult;
    if (pid2 == 0) {
        const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.HUP, &ign, null);
        const code = stop(.{ .signal = .HUP });
        linux.exit_group(code);
    }
    raw = 0;
    while (true) {
        const wr = linux.wait4(@intCast(pid2), &raw, 0, null);
        switch (linux.errno(wr)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TestUnexpectedResult,
        }
    }
    const status2: u32 = @bitCast(raw);
    try std.testing.expect(linux.W.IFEXITED(status2));
    try std.testing.expectEqual(@as(u8, 129), linux.W.EXITSTATUS(status2));
}

test "Guard.run does not launch child when a guarded signal already arrived" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/guard-prefork-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(root);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const marker = try std.fs.path.join(a, &.{ root, "ran" });

    for ([_]linux.SIG{ .TERM, .INT }) |sig| {
        const guard = Guard.hold();
        defer guard.release();
        _ = linux.kill(linux.getpid(), sig);
        const no_env: proc.Envp = &[_:null]?[*:0]const u8{};
        const cmd = try std.fmt.allocPrint(a, "echo ran > '{s}'", .{marker});
        const ran = guard.run(a, &.{ "/bin/sh", "-c", cmd }, no_env);
        switch (ran) {
            .signal => |got| try std.testing.expectEqual(sig, got),
            .exit => return error.TestUnexpectedResult,
        }
        try std.testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, marker, false));
    }
}

test "shell quoting reads back as the same word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shellQuote = common.pytext.shellQuote;
    try std.testing.expectEqualStrings("EESSI/2026.06", try shellQuote(a, "EESSI/2026.06"));
    try std.testing.expectEqualStrings("/home/u/eessi", try shellQuote(a, "/home/u/eessi"));
    try std.testing.expectEqualStrings("'owned space'", try shellQuote(a, "owned space"));
    try std.testing.expectEqualStrings("'a'\"'\"'b $(x)'", try shellQuote(a, "a'b $(x)"));
    try std.testing.expectEqualStrings("''", try shellQuote(a, ""));
}
