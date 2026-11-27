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
/// `--cpu-target`: targets, profiles, routes and the preflight decision.
pub const cpumask = @import("cpumask.zig");
/// `eb-local overlay`: declarative site overlays for upstream easyconfigs.
pub const recipe_overlay = @import("recipe_overlay.zig");
/// `--json` for scriptable commands.
const jsonout = @import("jsonout.zig");
const Allocator = std.mem.Allocator;

const tool = "eb-local";
/// The version `eb-local --version` prints, and the release it is.
pub const version = "3.5.0";

const usage_text =
    \\eb-local: install and build software on top of EESSI 2026.06, into a
    \\directory you own.
    \\  Global: --workstation forces managed recipe builds onto private local
    \\          storage on this machine, even when Slurm is present.
    \\
    \\  eb-local <easyconfig> [eb options]   build and install with EasyBuild
    \\  eb-local --explain <easyconfig> [eb options]
    \\                                       the commands that build runs, as shell lines,
    \\                                       its checks as comments; creates and runs nothing
    \\  eb-local --variant perf|debug <easyconfig> [eb options]
    \\                                       build that easyconfig with debug symbols and frame
    \\                                       pointers (perf) or unoptimised (debug), as a module
    \\                                       whose version ends in -perf or -debug
    \\  eb-local --cpu-target TARGET [--mask auto|cpuid|kvm|tcg] [--no-audit] <easyconfig> [eb options]
    \\                                       build for another CPU target on this machine: TARGET is
    \\                                       an EESSI subdirectory (x86_64/amd/zen4) or its last
    \\                                       component (zen4). The build sees that CPU through the
    \\                                       route --mask picks, refuses to go on when the EESSI
    \\                                       detection, archspec, gcc and CPUID do not all name the
    \\                                       target, and audits the installed binaries for
    \\                                       instructions the target lacks
    \\  eb-local eb [--] [eb options]        load EESSI-extend and run eb; configured prefix, no Slurm job.
    \\                                       At most one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL,
    \\                                       EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL may be set, and a
    \\                                       present empty value counts as set; with none set,
    \\                                       configuration selects a user or project install.
    \\                                       eb runs only if the module's install path is in the
    \\                                       tree that variable selects
    \\  eb-local --explain eb [--] [eb options]
    \\                                       the script eb runs, with its arguments; runs nothing
    \\  eb-local env [--strict] [--json]       lines that make your installed modules visible;
    \\                                       --strict exits when the EESSI init file is missing
    \\                                       (also when EB_LOCAL_ENV_STRICT=1)
    \\  eb-local dev [--strict] [--pure] [--replace] [--json] [--buildenv MODULE] [--envrc] [--lock | --locked] [MODULE...]
    \\                                       the same, plus MODULEs and a build environment,
    \\                                       so gcc, make, cmake and meson just work;
    \\                                       --strict exits when the EESSI init file is missing
    \\                                       (also when EB_LOCAL_ENV_STRICT=1);
    \\                                       --buildenv names the build environment to load;
    \\                                       --json prints the change as JSON, for env too;
    \\                                       --envrc writes that line to .envrc for direnv;
    \\                                       --pure purges loaded modules and LD_* first;
    \\                                       --replace records prior state and replaces the
    \\                                       modules loaded by an earlier --replace;
    \\                                       --lock records what loads in eb-local.lock,
    \\                                       --locked loads exactly that again
    \\  eb-local leave                       lines that restore the state before dev --replace
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
    \\  eb-local doctor [--json] [--strict] [--workspace PATH] [--cvmfs] [--cvmfs-parallel N] [--mpi] [--profiling] [--cpu-target TARGET]
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
    \\                                       --profiling reports whether perf may sample and
    \\                                       debuggers attach, and finds perf, valgrind and gdb
    \\                                       --cpu-target TARGET reports whether this machine can
    \\                                       present TARGET, and by which route
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
    \\Every configured command, including eb, takes --profile NAME, --project DIR
    \\(a shared project directory instead of $HOME/eessi), --config FILE and
    \\--workstation. The last forces managed builds onto this machine's disk.
    \\Use env and dev with eval:
    \\
    \\  eval "$(eb-local env)"
    \\  eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
    \\
    \\Configuration: the site file (the first of config.toml beside this program
    \\or its checkout root, /etc/eb-local/config.toml, eb-local.conf beside this
    \\program or its checkout root, and /etc/eb-local.conf), then
    \\~/.config/eb-local/config.toml,
    \\then EB_LOCAL_* variables (EB_LOCAL_SECRET_NAME=SOURCE for a secret),
    \\then options. Without sbatch on PATH or a nonempty SLURM_* variable,
    \\managed builds use private workstation storage automatically. Otherwise
    \\they use the allocation's own node-local mount; a successful build removes its workspace unless
    \\EB_LOCAL_KEEP_WORK=1. Secrets reach eb's environment only, and logs
    \\written during a build are cleaned of them. A build gets every secret,
    \\unless build.secrets or EB_LOCAL_BUILD_SECRETS names the ones it gets.
    \\
    \\--config FILE, or EB_LOCAL_CONFIG=FILE without it, is read in place of the
    \\site file when root or this program's owner owns it, otherwise in place of
    \\your ~/.config/eb-local/config.toml when you own it; the other file is
    \\still read, and only a site file may set the storage settings.
    \\
    \\The eb-local script in a source checkout resolves its real directory,
    \\tries zig-out/bin/eb-local there, then searches each PATH directory for
    \\another eb-local.
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

/// The list of what a command would change did not reach standard output, so
/// the command changes nothing.
fn unlisted(done: []const u8) u8 {
    warn("standard output is not writable; nothing was {s}", .{done});
    return 1;
}

var stdout: cli.Stdout = .{ .tool = tool };

/// Set in main from EB_LOCAL_TEST_STDOUT_WRITES, only in the test artifact:
/// that many writes to standard output succeed, and the next one and every
/// one after it fail as a full disk would, so a test can fail the write that
/// follows any given one.
var test_stdout_writes: ?usize = null;

fn emit(bytes: []const u8) bool {
    if (comptime build_options.test_ops) {
        if (test_stdout_writes) |left| {
            if (left == 0) {
                stdout.fd = sys.openat(linux.AT.FDCWD, "/dev/full", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch stdout.fd;
                test_stdout_writes = null;
            } else {
                test_stdout_writes = left - 1;
            }
        }
    }
    return stdout.write(bytes);
}

/// `fmt` and a newline in `buf`, or on `a` when `buf` is too small. Running
/// out of memory is an error to the caller, not a failed write.
fn formatLine(a: Allocator, buf: []u8, comptime fmt: []const u8, args: anytype) error{OutOfMemory}![]const u8 {
    if (std.fmt.bufPrint(buf, fmt ++ "\n", args)) |s| return s else |_| {}
    return std.fmt.allocPrint(a, fmt ++ "\n", args);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    if (stdout.failed) return;
    var buf: [4096]u8 = undefined;
    const s = formatLine(std.heap.page_allocator, &buf, fmt, args) catch oom();
    defer if (@intFromPtr(s.ptr) != @intFromPtr(&buf)) std.heap.page_allocator.free(s);
    _ = emit(s);
}

test "formatLine reports running out of memory instead of a failed write" {
    var small: [4]u8 = undefined;
    var big: [64]u8 = undefined;

    var never = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectEqualStrings("fits\n", try formatLine(never.allocator(), &big, "{s}", .{"fits"}));
    try std.testing.expect(!never.has_induced_failure);
    try std.testing.expectError(error.OutOfMemory, formatLine(never.allocator(), &small, "{s}", .{"too long for it"}));
    try std.testing.expect(never.has_induced_failure);

    var plenty = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const heap = try formatLine(plenty.allocator(), &small, "{s}", .{"too long for it"});
    defer std.testing.allocator.free(heap);
    try std.testing.expectEqualStrings("too long for it\n", heap);
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

/// How many names each `unset` line `env` and a build print takes, in the
/// order of `install_vars`: four names, one name, three names, four names.
const install_unset_groups = [_]usize{ 4, 1, 3, 4 };

comptime {
    var n: usize = 0;
    for (install_unset_groups) |size| n += size;
    std.debug.assert(n == install_vars.len);
}

/// The names `env` and a build unset: `install_vars`. The test artifact
/// takes another list of as many names from EB_LOCAL_TEST_INSTALL_VARS, so a
/// test sees both read one list.
fn installNames(a: Allocator, c: Ctx) []const []const u8 {
    if (build_options.test_ops) if (nonEmpty(c.env.get("EB_LOCAL_TEST_INSTALL_VARS"))) |value| {
        var names: std.ArrayList([]const u8) = .empty;
        var words = std.mem.tokenizeScalar(u8, value, ' ');
        while (words.next()) |word| {
            for (word) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return &install_vars;
            names.append(a, word) catch oom();
        }
        if (names.items.len == install_vars.len) return names.items;
    };
    return &install_vars;
}

/// The `unset` lines for `names`, grouped as `install_unset_groups` says.
fn installUnsetLines(a: Allocator, names: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var next: usize = 0;
    for (install_unset_groups) |size| {
        out.appendSlice(a, "unset") catch oom();
        for (names[next .. next + size]) |name| out.print(a, " {s}", .{name}) catch oom();
        out.append(a, '\n') catch oom();
        next += size;
    }
    return out.items;
}

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

/// The configured user or project install selected by `place`. Env, builds,
/// eb and doctor all use this value, so they cannot disagree about the
/// variable that names the configured prefix.
const ConfiguredInstall = struct {
    prefix: []const u8,
    mode: extend.Mode,

    fn variable(self: ConfiguredInstall) []const u8 {
        return extend.variable(self.mode);
    }

    fn exportLine(self: ConfiguredInstall, a: Allocator) []const u8 {
        return str(a, "export {s}={s}\n", .{ self.variable(), q(a, self.prefix) });
    }

    fn setting(self: ConfiguredInstall) []const u8 {
        return if (self.mode == .project) "project" else "prefix";
    }
};

fn configuredInstall(p: Place) ConfiguredInstall {
    return .{ .prefix = p.prefix, .mode = if (p.project) .project else .user };
}

fn matchesConfiguredInstall(c: Ctx, configured: ConfiguredInstall, selected: extend.Selection, value: []const u8) bool {
    if (selected.mode != configured.mode) return false;
    const explicit = storage.canonical(c.a, value, c.cwd) catch return false;
    return std.mem.eql(u8, explicit, configured.prefix);
}

/// What `eb-local env` set, if NAME=VALUE is that: its install variable,
/// naming P's prefix, or, when the extension env loads for a prefix that
/// exists is loaded, the install path it chose in the prefix's versions
/// tree, or the EasyBuild prefix it sets beside that path.
fn ownInstallVar(c: Ctx, s: config.Settings, p: Place, name: []const u8, value: []const u8) ?[]const u8 {
    const mine = configuredInstall(p).variable();
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

fn isModule(module: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, module, name)) return true;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    return std.mem.startsWith(u8, module, name) and module.len > name.len and module[name.len] == '/';
}

/// Whether Lmod lists MODULE, a name or a name and version, as loaded.
fn moduleLoaded(c: Ctx, module: []const u8) bool {
    var it = std.mem.splitScalar(u8, c.env.get("LOADEDMODULES") orelse "", ':');
    while (it.next()) |m| if (isModule(m, module)) return true;
    return false;
}

test "isModule matches an unversioned name or the exact configured module" {
    try std.testing.expect(isModule("EESSI/2026.06", "EESSI"));
    try std.testing.expect(isModule("EESSI/2026.06", "EESSI/2026.06"));
    try std.testing.expect(!isModule("EESSI/2026.06/debug", "EESSI/2026.06"));
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

/// `dev --pure`: start from no loaded modules and no loader variables, so
/// what the shell had before does not reach the build environment. Sticky
/// modules stay, as `module purge` leaves them.
const pure_prelude =
    \\module purge >/dev/null 2>&1 || true
    \\unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
    \\
;

/// The wrapper makes a missing module command fail the evaluated lines without
/// ending an interactive shell or applying a partial environment.
const module_missing =
    \\type module >/dev/null 2>&1 || {
    \\    echo "eb-local: no module command found; the lines change nothing" >&2
    \\    return 1
    \\}
    \\
;

fn environmentLines(c: Ctx, s: config.Settings, p: Place, pure: bool, setup: []const u8) []const u8 {
    return environmentPrelude(c, s, p, pure, setup, true);
}

/// `load_extend` is false when a dev lock already names the extension, so the
/// prelude does not load it again. The lock loads that module once, inside
/// the CPU target guard.
fn environmentPrelude(c: Ctx, s: config.Settings, p: Place, pure: bool, setup: []const u8, load_extend: bool) []const u8 {
    const a = c.a;
    const install = configuredInstall(p);
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    add(a, &out, lmod_init);
    add(a, &out, module_missing);
    add(a, &out, setup);
    if (pure) add(a, &out, pure_prelude);
    add(a, &out, str(a, "module unload {s} >/dev/null 2>&1 || true\n", .{q(a, s.extend_module.value)}));
    add(a, &out, installUnsetLines(a, installNames(a, c)));
    add(a, &out, install.exportLine(a));
    // [eessi] settings before the stack loads: the EESSI module and its
    // hooks read them then.
    for (s.eessi.items) |v| add(a, &out, str(a, "export {s}={s}\n", .{ v.name, q(a, v.value) }));
    add(a, &out, str(a, "eb_local_stack={s}\n", .{q(a, s.stack_module.value)}));
    add(a, &out, eessi_modules ++ "unset eb_local_stack\n");
    // Lmod finds every module of a load before it loads any, and the
    // extension is on MODULEPATH only once the stack is loaded, so each has
    // a load of its own. EESSI-extend refuses an install directory that does
    // not exist; before the first install there are no modules of yours to
    // show, so the stack is loaded alone.
    add(a, &out, str(a, "module load {s}\n", .{q(a, s.stack_module.value)}));
    // Tasks run with the CPU target eessi-arch-guard selects, which can be
    // below the one EESSI detects; where the guard is installed, it moves the
    // stack there before EESSI-extend reads its install path.
    add(a, &out,
        \\if command -v eessi-arch-guard >/dev/null 2>&1; then
        \\    if _eb_local_arch_delta=$(eessi-arch-guard --shell); then
        \\        eval "$_eb_local_arch_delta"
        \\        unset _eb_local_arch_delta
        \\    else
        \\        local _eb_local_arch_status=$?
        \\        unset _eb_local_arch_delta
        \\        if [ -n "${eb_local_dev_saved_base+x}" ]; then
        \\            EB_LOCAL_DEV_SAVED=$(printf '%s\nactive:%s' "$eb_local_dev_saved_base" "${LOADEDMODULES-}")
        \\            export EB_LOCAL_DEV_SAVED
        \\            unset eb_local_dev_saved_base
        \\        fi
        \\        return "$_eb_local_arch_status"
        \\    fi
        \\fi
        \\
    );
    if (load_extend) {
        const exists_dir = if (fsx.statAt(fsx.cwd, p.prefix, true)) |st| st.isDir() else |_| false;
        if (exists_dir) add(a, &out, str(a, "module load {s}\n", .{q(a, s.extend_module.value)}));
    }
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

/// Run `body` in one function so a guard can return without exiting the
/// evaluating shell. Strict setup remains outside the wrapper.
fn shellApply(a: Allocator, body: []const u8) []const u8 {
    const nl = if (body.len == 0 or body[body.len - 1] != '\n') "\n" else "";
    return str(a,
        \\eb_local_apply() {{
        \\    local _eb_local_wrap eb_local_family eb_local_buildenv eb_local_level
        \\{s}{s}}}
        \\eb_local_apply
        \\_eb_local_status=$?
        \\unset -f eb_local_apply
        \\eval "unset _eb_local_status; (exit $_eb_local_status)"
        \\
    , .{ body, nl });
}

fn emittedLines(a: Allocator, strict: bool, body: []const u8) []const u8 {
    const applied = shellApply(a, body);
    if (!strict) return applied;
    return str(a, "{s}{s}", .{ env_strict_prelude, applied });
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
    if (std.mem.eql(u8, command, "--explain")) {
        if (g.variant) |v| parts.appendSlice(a, &.{ "--variant", v }) catch oom();
        parts.appendSlice(a, maskOptionWords(a, g)) catch oom();
    }
    if (std.mem.eql(u8, command, "dev")) {
        if (g.pure) parts.append(a, "--pure") catch oom();
        if (g.replace) parts.append(a, "--replace") catch oom();
        if (g.locked) parts.append(a, "--locked") catch oom();
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
    return fsx.readAll(c.a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ path, storage.describeError(e) });
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
    /// Force a managed build to use this machine's private local storage.
    workstation: bool = false,
    /// `--variant NAME`: build the named easyconfig as that variant.
    variant: ?[]const u8 = null,
    /// `--cpu-target TARGET`: build for this CPU target.
    cpu_target: ?[]const u8 = null,
    /// `--mask`: how `--cpu-target` presents the target.
    mask: cpumask.Mode = .auto,
    /// `--no-audit`: skip the instruction audit after a `--cpu-target` build.
    no_audit: bool = false,
    /// `env --strict`: refuse to print load lines when the EESSI init path is absent.
    env_strict: bool = false,
    /// One line of JSON on stdout instead of the human report.
    json_out: bool = false,
    /// `dev --envrc`: write the dev line to `.envrc` here, for direnv.
    envrc: bool = false,
    /// `dev --pure`: purge the loaded modules and the loader variables first.
    pure: bool = false,
    /// `dev --replace`: remember the caller and replace an earlier recorded dev.
    replace: bool = false,
    /// `dev --lock`: write what the dev lines load to `eb-local.lock`.
    lock: bool = false,
    /// `dev --locked`: load the modules of `eb-local.lock`, and only those.
    locked: bool = false,
};

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const x = v orelse return null;
    return if (x.len > 0) x else null;
}

/// When the binary sits at `<checkout>/zig-out/bin/eb-local`, the
/// checkout directory `<checkout>`, else `null`.
fn checkoutRoot(dir: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(dir), "bin")) return null;
    const zig_out = std.fs.path.dirname(dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(zig_out), "zig-out")) return null;
    const root = std.fs.path.dirname(zig_out) orelse return null;
    return if (root.len > 0) root else null;
}

/// Ordered site-layer candidates for a binary in `dir`. A build inside
/// `<checkout>/zig-out/bin` also checks `<checkout>` before `/etc`.
fn siteConfigCandidates(a: Allocator, dir: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.append(a, std.fs.path.join(a, &.{ dir, "config.toml" }) catch oom()) catch oom();
    if (checkoutRoot(dir)) |root| {
        list.append(a, std.fs.path.join(a, &.{ root, "config.toml" }) catch oom()) catch oom();
    }
    list.append(a, "/etc/eb-local/config.toml") catch oom();
    list.append(a, std.fs.path.join(a, &.{ dir, "eb-local.conf" }) catch oom()) catch oom();
    if (checkoutRoot(dir)) |root| {
        list.append(a, std.fs.path.join(a, &.{ root, "eb-local.conf" }) catch oom()) catch oom();
    }
    list.append(a, "/etc/eb-local.conf") catch oom();
    return list.items;
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
        for (siteConfigCandidates(c.a, selfDir(c.a))) |p| if (exists(p)) {
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

/// Run `lines` in a bash child and return its environment afterwards, as
/// `env -0` prints it. What the lines print goes to stderr. Null, with a
/// message, when the child cannot run or the lines fail. `status` is the child
/// status on failure and zero when the environment is captured.
fn runLines(c: Ctx, kind: []const u8, lines: []const u8, status: *u8) ?[]const u8 {
    status.* = 1;
    const a = c.a;
    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    const tmp = nonEmpty(c.env.get("TMPDIR")) orelse "/tmp";
    const base = if (fsx.statAt(fsx.cwd, tmp, true)) |st| (if (st.isDir()) tmp else "/tmp") else |_| "/tmp";
    const dir = storage.makeWorkspace(a, base) catch |e| {
        warn("could not create a temporary directory in {s} for {s}: {s}", .{ base, kind, @errorName(e) });
        return null;
    };
    defer storage.removeTree(a, dir) catch {};
    const out_path = std.fs.path.join(a, &.{ dir, "env0" }) catch oom();
    const nl = if (lines.len == 0 or lines[lines.len - 1] != '\n') "\n" else "";
    const script = str(a, "_eb_local_env0=$1\nshift\nexec 1>&2\n{s}{s}_eb_local_lines_status=$?\n[ \"$_eb_local_lines_status\" -eq 0 ] || exit \"$_eb_local_lines_status\"\nenv -0 >\"$_eb_local_env0\"\n", .{ lines, nl });
    const r = proc.run(a, bash, &.{ bash, "--noprofile", "--norc", "-c", script, "eb-local", out_path }, c.envp, .{
        .stdout_limit = 4096,
        .stderr_limit = 1 << 20,
        .timeout_ms = 300_000,
        .new_session = true,
        .end_with_leader = true,
    }) catch |e| {
        warn("could not run the {s} lines in bash: {s}", .{ kind, @errorName(e) });
        return null;
    };
    defer r.deinit(a);
    if (r.stderr.len > 0) cli.put(2, r.stderr);
    if (r.term.code() != 0) {
        status.* = @intCast(r.term.code());
        warn("the {s} lines failed in bash (status {d}); nothing is written", .{ kind, r.term.code() });
        return null;
    }
    const opened = fsx.openRegular(fsx.cwd, out_path, false) catch |e| {
        warn("could not read captured {s} environment: {s}", .{ kind, @errorName(e) });
        return null;
    };
    defer sys.close(opened.fd);
    const env0 = fsx.readAll(a, opened.fd, 8 << 20) catch |e| {
        warn("could not read captured {s} environment: {s}", .{ kind, @errorName(e) });
        return null;
    };
    status.* = 0;
    return env0;
}

/// The value of `name` in the output of `env -0`, or "" when it is not set.
fn env0Value(env0: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, env0, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
    }
    return "";
}

fn testSelfFdCount() !usize {
    const dir = try sys.openat(linux.AT.FDCWD, "/proc/self/fd", .{ .DIRECTORY = true }, 0);
    defer sys.close(dir);
    var count: usize = 0;
    var dents: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dir, &dents, dents.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var pos: usize = 0;
        while (pos < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(dents[pos..].ptr);
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(dents[pos + @offsetOf(linux.dirent64, "name") ..].ptr)));
            pos += d.reclen;
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
        }
    }
    return count - 1;
}

test "runLines cleans temporary directory and descriptors on failure and success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const scratch = try std.fmt.allocPrint(a, "{s}/.zig-cache/runlines-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(scratch);
    defer storage.removeTree(a, scratch) catch {};

    var map: std.process.Environ.Map = .init(a);
    try map.put("PATH", "/usr/bin:/bin");
    try map.put("TMPDIR", scratch);
    const ctx: Ctx = .{
        .a = a,
        .io = std.testing.io,
        .cwd = cwd,
        .env = &map,
        .envp = envpOf(a, &map),
    };

    const before = try testSelfFdCount();
    const failed_res = blk: {
        const saved_rc = linux.fcntl(2, linux.F.DUPFD_CLOEXEC, @as(usize, 3));
        if (linux.errno(saved_rc) != .SUCCESS) return error.Unexpected;
        const saved_err: sys.fd_t = @intCast(saved_rc);
        defer sys.close(saved_err);
        const null_fd = try sys.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        defer sys.close(null_fd);
        _ = linux.dup2(null_fd, 2);
        defer _ = linux.dup2(saved_err, 2);
        var status: u8 = 0;
        const result = runLines(ctx, "env", "exit 7", &status);
        try std.testing.expectEqual(@as(u8, 7), status);
        break :blk result;
    };
    try std.testing.expect(failed_res == null);
    try std.testing.expectEqual(before, try testSelfFdCount());

    var status: u8 = 1;
    const ok = runLines(ctx, "env", "export DEMO_KEY=ok", &status) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualStrings("ok", env0Value(ok, "DEMO_KEY"));
    try std.testing.expectEqual(before, try testSelfFdCount());
}

fn emitEnvChange(c: Ctx, kind: []const u8, lines: []const u8) u8 {
    const a = c.a;
    var status: u8 = 1;
    const env0 = runLines(c, kind, lines, &status) orelse return status;
    var set: std.ArrayList(EnvVar) = .empty;
    var after: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, env0, 0);
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
    const lines = emittedLines(c.a, envStrict(c, g), environmentLines(c, s, p, false, ""));
    if (g.json_out) return emitEnvChange(c, "env", lines);
    evalHint(replay(c.a, "env", s, g, p.prefix, &.{}));
    return if (emit(lines)) 0 else 1;
}

const dev_saved_names = [_][]const u8{
    "PATH",
    "EB_LOCAL_DEV_PREFIX",
    "EB_LOCAL_RPATH_WRAPPERS",
    "CMAKE_ARGS",
    "EB_LOCAL_MESON_INSTALL_RPATH",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LD_AUDIT",
    "JULIA_DEPOT_PATH",
    "R_LIBS_USER",
    "PYTHONUSERBASE",
    "GOPATH",
    "GOMODCACHE",
    "EB_LOCAL_DEV_GO_PREFIX",
};

const dev_saved_names_v2 = [_][]const u8{
    "PATH",
    "EB_LOCAL_DEV_PREFIX",
    "EB_LOCAL_RPATH_WRAPPERS",
    "CMAKE_ARGS",
    "EB_LOCAL_MESON_INSTALL_RPATH",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LD_AUDIT",
};

const dev_saved_names_v1 = [_][]const u8{
    "PATH",
    "EB_LOCAL_DEV_PREFIX",
    "EB_LOCAL_RPATH_WRAPPERS",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LD_AUDIT",
};

const SavedVar = struct {
    present: bool,
    value: []const u8 = "",
};

const DevSaved = struct {
    prior: []const u8,
    active: []const u8,
    values: [dev_saved_names.len]SavedVar,
    base: []const u8,
};

fn validModuleList(text: []const u8) bool {
    if (text.len == 0) return true;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |module| {
        if (!config.validModule(module)) return false;
    }
    return true;
}

fn moduleInList(list: []const u8, wanted: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |module| {
        if (std.mem.eql(u8, module, wanted)) return true;
    }
    return false;
}

fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        else => null,
    };
}

fn hexEncode(a: Allocator, text: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    const out = a.alloc(u8, text.len * 2) catch oom();
    for (text, 0..) |ch, i| {
        out[i * 2] = digits[ch >> 4];
        out[i * 2 + 1] = digits[ch & 15];
    }
    return out;
}

fn hexDecode(a: Allocator, text: []const u8) ?[]const u8 {
    if (text.len % 2 != 0) return null;
    const out = a.alloc(u8, text.len / 2) catch oom();
    var i: usize = 0;
    while (i < text.len) : (i += 2) {
        const high = hexNibble(text[i]) orelse return null;
        const low = hexNibble(text[i + 1]) orelse return null;
        const byte = high * 16 + low;
        if (byte == 0) return null;
        out[i / 2] = byte;
    }
    return out;
}

fn savedValue(c: Ctx, line: []const u8, name: []const u8) SavedVar {
    if (!std.mem.startsWith(u8, line, name) or line.len <= name.len or line[name.len] != ':')
        die("EB_LOCAL_DEV_SAVED is not a state eb-local can restore", .{});
    const encoded = line[name.len + 1 ..];
    if (std.mem.eql(u8, encoded, "u")) return .{ .present = false };
    if (encoded.len == 0 or encoded[0] != 's')
        die("EB_LOCAL_DEV_SAVED contains an invalid value", .{});
    return .{
        .present = true,
        .value = hexDecode(c.a, encoded[1..]) orelse
            die("EB_LOCAL_DEV_SAVED contains an invalid value", .{}),
    };
}

fn parseDevSaved(c: Ctx, text: []const u8) DevSaved {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| lines.append(c.a, line) catch oom();
    if (lines.items.len == 0)
        die("EB_LOCAL_DEV_SAVED is not a state eb-local can restore", .{});
    const names: []const []const u8 = if (std.mem.eql(u8, lines.items[0], "eb-local-dev-v3"))
        &dev_saved_names
    else if (std.mem.eql(u8, lines.items[0], "eb-local-dev-v2"))
        &dev_saved_names_v2
    else if (std.mem.eql(u8, lines.items[0], "eb-local-dev-v1"))
        &dev_saved_names_v1
    else
        die("EB_LOCAL_DEV_SAVED has an unsupported version", .{});
    if (lines.items.len != names.len + 3)
        die("EB_LOCAL_DEV_SAVED is not a state eb-local can restore", .{});
    if (!std.mem.startsWith(u8, lines.items[1], "prior:"))
        die("EB_LOCAL_DEV_SAVED is not a state eb-local can restore", .{});
    const prior = lines.items[1]["prior:".len..];
    if (!validModuleList(prior))
        die("EB_LOCAL_DEV_SAVED contains an invalid prior module list", .{});
    var values: [dev_saved_names.len]SavedVar = @splat(.{ .present = false });
    for (names, 0..) |name, i| {
        const value = savedValue(c, lines.items[i + 2], name);
        for (dev_saved_names, 0..) |current, j| {
            if (std.mem.eql(u8, name, current)) values[j] = value;
        }
    }
    const active_line = lines.items[names.len + 2];
    if (!std.mem.startsWith(u8, active_line, "active:"))
        die("EB_LOCAL_DEV_SAVED is not a state eb-local can restore", .{});
    const active = active_line["active:".len..];
    if (!validModuleList(active))
        die("EB_LOCAL_DEV_SAVED contains an invalid active module list", .{});
    const marker = std.mem.lastIndexOf(u8, text, "\nactive:") orelse unreachable;
    return .{ .prior = prior, .active = active, .values = values, .base = text[0..marker] };
}

fn newDevSaved(c: Ctx) DevSaved {
    const prior = c.env.get("LOADEDMODULES") orelse "";
    if (!validModuleList(prior))
        die("LOADEDMODULES contains a module name that cannot be recorded", .{});
    var values: [dev_saved_names.len]SavedVar = undefined;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(c.a, "eb-local-dev-v3\nprior:") catch oom();
    out.appendSlice(c.a, prior) catch oom();
    for (dev_saved_names, 0..) |name, i| {
        out.append(c.a, '\n') catch oom();
        out.appendSlice(c.a, name) catch oom();
        out.append(c.a, ':') catch oom();
        if (c.env.get(name)) |value| {
            values[i] = .{ .present = true, .value = value };
            out.append(c.a, 's') catch oom();
            out.appendSlice(c.a, hexEncode(c.a, value)) catch oom();
        } else {
            values[i] = .{ .present = false };
            out.append(c.a, 'u') catch oom();
        }
    }
    return .{ .prior = prior, .active = "", .values = values, .base = out.items };
}

fn currentDevSaved(c: Ctx) DevSaved {
    return if (c.env.get("EB_LOCAL_DEV_SAVED")) |text| parseDevSaved(c, text) else newDevSaved(c);
}

fn moduleRestoreLines(c: Ctx, saved: DevSaved) []const u8 {
    const current = c.env.get("LOADEDMODULES") orelse "";
    if (!validModuleList(current))
        die("LOADEDMODULES contains a module name that cannot be restored", .{});
    var out: std.ArrayList(u8) = .empty;
    var wrote_unload = false;
    var it = std.mem.splitScalar(u8, current, ':');
    while (it.next()) |module| {
        if (module.len == 0 or moduleInList(saved.prior, module)) continue;
        if (!wrote_unload) {
            out.appendSlice(c.a, "module unload") catch oom();
            wrote_unload = true;
        }
        out.appendSlice(c.a, str(c.a, " {s}", .{q(c.a, module)})) catch oom();
    }
    if (wrote_unload) out.append(c.a, '\n') catch oom();
    if (saved.prior.len > 0) {
        out.appendSlice(c.a, "module load") catch oom();
        it = std.mem.splitScalar(u8, saved.prior, ':');
        while (it.next()) |module|
            out.appendSlice(c.a, str(c.a, " {s}", .{q(c.a, module)})) catch oom();
        out.append(c.a, '\n') catch oom();
    }
    return out.items;
}

fn cmdLeave(c: Ctx) u8 {
    const text = c.env.get("EB_LOCAL_DEV_SAVED") orelse
        die("there is no recorded dev environment to leave", .{});
    const saved = parseDevSaved(c, text);
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(c.a, moduleRestoreLines(c, saved)) catch oom();
    for (dev_saved_names, saved.values) |name, value| {
        if (value.present) {
            out.appendSlice(c.a, str(c.a, "export {s}={s}\n", .{ name, q(c.a, value.value) })) catch oom();
        } else {
            out.appendSlice(c.a, str(c.a, "unset {s}\n", .{name})) catch oom();
        }
    }
    out.appendSlice(c.a, "unset EB_LOCAL_DEV_SAVED\n") catch oom();
    evalHint("leave");
    return if (emit(out.items)) 0 else 1;
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
    var exists_already = false;
    const old: []const u8 = if (fsx.openRegular(fsx.cwd, ".envrc", true)) |opened| blk: {
        defer sys.close(opened.fd);
        exists_already = true;
        break :blk fsx.readAll(a, opened.fd, 1 << 20) catch |e| die("cannot read .envrc ({s})", .{storage.describeError(e)});
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
    if (exists_already) {
        // Written beside the old file and renamed over it, with its mode.
        fsx.replaceContents(a, fsx.cwd, ".envrc", text) catch |e| die("cannot write .envrc ({s})", .{storage.describeError(e)});
    } else {
        const fd = sys.openat(fsx.cwd, ".envrc", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644) catch |e|
            die("cannot create .envrc ({s})", .{storage.describeError(e)});
        sys.writeAll(fd, text) catch |e| die("cannot write .envrc ({s})", .{storage.describeError(e)});
        storage.closeWritten(fd) catch |e| die("cannot write .envrc ({s})", .{storage.describeError(e)});
    }
    cli.err("eb-local: wrote .envrc in {s}; run `direnv allow` there to load it\n", .{c.cwd});
    return 0;
}

/// The file `dev --lock` writes and `dev --locked` reads, in the working directory.
const lock_name = "eb-local.lock";

/// What a dev environment resolved to: enough for a later shell to load the
/// same modules, and to notice that it cannot.
const DevLock = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "dev-lock",
    /// `stack.module` when the lock was written.
    stack: []const u8,
    eessi_version: []const u8 = "",
    /// EESSI_SOFTWARE_SUBDIR: the CPU target the modules were resolved for.
    /// Nodes with the same CPU share it, whatever their accelerator.
    cpu_target: []const u8,
    accelerator_target: []const u8 = "",
    /// LOADEDMODULES in load order: every module, each with its version.
    modules: []const []const u8,
};

/// Create `name` in the working directory, or replace it atomically with its mode kept.
fn writeCwdFile(a: Allocator, name: []const u8, text: []const u8) void {
    if (fsx.statAt(fsx.cwd, name, true)) |_| {
        fsx.replaceContents(a, fsx.cwd, name, text) catch |e| die("cannot write {s} ({s})", .{ name, storage.describeError(e) });
    } else |_| {
        const fd = sys.openat(fsx.cwd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644) catch |e|
            die("cannot create {s} ({s})", .{ name, storage.describeError(e) });
        sys.writeAll(fd, text) catch |e| die("cannot write {s} ({s})", .{ name, storage.describeError(e) });
        storage.closeWritten(fd) catch |e| die("cannot write {s} ({s})", .{ name, storage.describeError(e) });
    }
}

/// `dev --lock`: run the dev lines in a bash child and record what loaded.
fn writeLock(c: Ctx, s: config.Settings, lines: []const u8) u8 {
    const a = c.a;
    var status: u8 = 1;
    const env0 = runLines(c, "dev", lines, &status) orelse return status;
    var modules: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, env0Value(env0, "LOADEDMODULES"), ':');
    while (it.next()) |m| {
        if (m.len > 0) modules.append(a, m) catch oom();
    }
    const cpu = env0Value(env0, "EESSI_SOFTWARE_SUBDIR");
    if (cpu.len == 0 or modules.items.len == 0) {
        warn("the dev lines loaded no module or set no EESSI_SOFTWARE_SUBDIR, so there is nothing to lock; {s} is not written", .{lock_name});
        return 1;
    }
    const text = jsonout.renderLine(a, DevLock{
        .stack = s.stack_module.value,
        .eessi_version = env0Value(env0, "EESSI_VERSION"),
        .cpu_target = cpu,
        .accelerator_target = env0Value(env0, "EESSI_ACCELERATOR_TARGET"),
        .modules = modules.items,
    }) catch oom();
    writeCwdFile(a, lock_name, text);
    cli.err("eb-local: wrote {s}: {d} modules for {s}; `eb-local dev --locked` loads them again\n", .{ lock_name, modules.items.len, cpu });
    return 0;
}

/// A CPU target as EESSI names one: path parts of letters, digits, `_`, `.` and `-`.
fn validTarget(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '/');
    var any = false;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-')) return false;
        }
        any = true;
    }
    return any;
}

fn lockedModule(modules: []const []const u8, wanted: []const u8) ?[]const u8 {
    for (modules) |m| if (isModule(m, wanted)) return m;
    return null;
}

fn hasBuildenvModule(s: config.Settings, modules: []const []const u8) bool {
    for (modules) |m| {
        if (std.mem.startsWith(u8, m, "buildenv/")) return true;
        if (std.mem.eql(u8, m, s.dev_buildenv.value)) return true;
        for (s.buildenv_for) |b| if (b.value.len > 0 and std.mem.eql(u8, m, b.value)) return true;
    }
    return false;
}

/// Shell that stores `eb-local rpath-wrappers ARGS` in `name` and returns
/// that command's status when it fails. The lines run inside `eb_local_apply`,
/// so a failure returns from that function instead of exiting the shell.
/// `eval "$(...)"` would discard the status and let the function continue.
fn rpathCapture(a: Allocator, exe: []const u8, args: []const u8, name: []const u8) []const u8 {
    return str(a, "{s}=$({s} rpath-wrappers {s}) || return $?\n", .{ name, exe, args });
}

/// The `rpath-wrappers` lines for a locked dev shell. Each command is
/// captured and checked before it is evaluated, so a failure leaves
/// `EB_LOCAL_RPATH_WRAPPERS` unset. The caller exports
/// `EB_LOCAL_DEV_PREFIX` only after these lines, which return on failure.
/// A lock with no build environment runs only `--for`. That wraps every
/// name in `rpath.names`, and `rpath.self_linking` is a subset, so a
/// following `--unwrapped` is not needed. Capturing it before `--for` is
/// on `PATH` would miss `.eb-local-rpath`, wrap those compilers again,
/// and leave the first directory behind after `drop_rpath_wrappers`.
fn lockedRpathWrapperLines(c: Ctx, s: config.Settings, modules: []const []const u8) []const u8 {
    const a = c.a;
    var exe_buf: [sys.path_max]u8 = undefined;
    const exe = q(a, selfExe(&exe_buf) orelse tool);
    if (hasBuildenvModule(s, modules)) {
        const cap_unwrapped = rpathCapture(a, exe, "--unwrapped", "_eb_local_unwrapped");
        return str(a, "{s}{s}{s}", .{
            \\local _eb_local_unwrapped
            \\
            ,
            cap_unwrapped,
            \\eval "$_eb_local_unwrapped"
            \\unset _eb_local_unwrapped
            \\
        });
    }
    return str(a, "{s}{s}unset eb_local_family\n", .{
        familyDetectLines(a),
        rpathEval(a, str(a, "{s} rpath-wrappers --for \"$eb_local_family\"", .{exe})),
    });
}

/// `dev --locked`: the lines that load exactly the modules of `eb-local.lock`,
/// from a purged shell, and that load nothing when this shell's CPU target is
/// not the lock's, or when the lock records an EESSI version and this shell's
/// is different. The same binaries serve every node with that CPU target, so
/// a lock written on one node type loads on another that shares it. A lock
/// with no recorded version still loads.
fn lockedLines(c: Ctx, s: config.Settings, g: Global, installed: Place) u8 {
    const a = c.a;
    const opened = fsx.openRegular(fsx.cwd, lock_name, true) catch
        die("there is no {s} here; write one with `eb-local dev --lock MODULE...`", .{lock_name});
    defer sys.close(opened.fd);
    const text = fsx.readAll(a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ lock_name, storage.describeError(e) });
    const lock = std.json.parseFromSliceLeaky(DevLock, a, text, .{ .ignore_unknown_fields = true }) catch
        die("{s} is not a lock eb-local wrote; write it again with `eb-local dev --lock MODULE...`", .{lock_name});
    if (!std.mem.eql(u8, lock.kind, "dev-lock") or lock.schema_version != jsonout.schema_version)
        die("{s} is not a dev lock of this eb-local (kind {s}, schema {d})", .{ lock_name, lock.kind, lock.schema_version });
    if (!validTarget(lock.cpu_target)) die("{s} names no usable CPU target", .{lock_name});
    if (lock.modules.len == 0) die("{s} lists no modules", .{lock_name});
    for (lock.modules) |m| {
        if (!config.validModule(m)) die("{s} lists '{s}', which is not a module name", .{ lock_name, m });
    }
    if (!std.mem.eql(u8, lock.stack, s.stack_module.value))
        die("{s} was written with the stack {s}; this configuration loads {s}. Write the lock again, or select that stack", .{ lock_name, lock.stack, s.stack_module.value });
    const locked_extend = lockedModule(lock.modules, s.extend_module.value);
    var out: std.ArrayList(u8) = .empty;
    // Skip the prelude's extension load when the lock already names it. The
    // extension is then loaded once inside the target guard, and the stack
    // is left off the locked module line because the prelude loaded it.
    out.appendSlice(a, environmentPrelude(c, s, installed, true, "", locked_extend == null)) catch oom();
    out.appendSlice(a, str(a,
        \\if [ "${{EESSI_SOFTWARE_SUBDIR-}}" != {s} ]; then
        \\    echo "eb-local: {s} was written for the CPU target "{s}", and this shell has ${{EESSI_SOFTWARE_SUBDIR:-none}}; its modules are not loaded." >&2
        \\
    , .{ q(a, lock.cpu_target), lock_name, q(a, lock.cpu_target) })) catch oom();
    // The stack module can keep its name across an EESSI release, and the
    // CPU subdir often does too. The version is what says these modules
    // were resolved for another release. An empty one is a lock from before
    // the field was recorded, and still loads.
    if (lock.eessi_version.len > 0) out.appendSlice(a, str(a,
        \\elif [ "${{EESSI_VERSION-}}" != {s} ]; then
        \\    echo "eb-local: {s} was written for EESSI "{s}", and this shell has ${{EESSI_VERSION:-none}}; its modules are not loaded." >&2
        \\
    , .{ q(a, lock.eessi_version), lock_name, q(a, lock.eessi_version) })) catch oom();
    out.appendSlice(a, "else\n") catch oom();
    // Lmod resolves every name on one load line before loading any of them,
    // and the extension is on MODULEPATH only after the stack. Load a
    // recorded extension on its own line first.
    if (locked_extend) |m| out.appendSlice(a, str(a, "module load {s}\n", .{q(a, m)})) catch oom();
    var loaded: usize = 0;
    for (lock.modules) |m| {
        if (isModule(m, s.stack_module.value) or isModule(m, s.extend_module.value)) continue;
        if (loaded == 0) out.appendSlice(a, "module load") catch oom();
        out.appendSlice(a, str(a, " {s}", .{q(a, m)})) catch oom();
        loaded += 1;
    }
    if (loaded > 0) out.append(a, '\n') catch oom();
    out.appendSlice(a, drop_rpath_wrappers) catch oom();
    out.appendSlice(a, lockedRpathWrapperLines(c, s, lock.modules)) catch oom();
    out.appendSlice(a, installed_rpath_settings) catch oom();
    out.appendSlice(a, host_ca_bundle) catch oom();
    const dev_root = std.fs.path.join(a, &.{ installed.prefix, "dev" }) catch oom();
    out.appendSlice(a, str(a, "export EB_LOCAL_DEV_PREFIX={s}\"/${{EESSI_VERSION-}}/${{EESSI_SOFTWARE_SUBDIR-}}${{EESSI_ACCELERATOR_TARGET:+/$EESSI_ACCELERATOR_TARGET}}\"\n", .{q(a, dev_root)})) catch oom();
    out.appendSlice(a, extend.cargo_linker) catch oom();
    out.appendSlice(a, dev_lang_dirs) catch oom();
    out.appendSlice(a, "fi\n") catch oom();
    const lines = emittedLines(a, envStrict(c, g), out.items);
    if (g.json_out) return emitEnvChange(c, "dev", lines);
    evalHint("dev --locked");
    return if (emit(lines)) 0 else 1;
}

fn replacePrelude(c: Ctx, saved: DevSaved) []const u8 {
    const current = c.env.get("LOADEDMODULES") orelse "";
    if (!validModuleList(current))
        die("LOADEDMODULES contains a module name that cannot be replaced", .{});
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(c.a, str(c.a, "local eb_local_dev_saved_base={s}\n", .{q(c.a, saved.base)})) catch oom();
    var wrote_unload = false;
    var it = std.mem.splitScalar(u8, saved.active, ':');
    while (it.next()) |module| {
        if (module.len == 0 or moduleInList(saved.prior, module) or !moduleInList(current, module)) continue;
        if (!wrote_unload) {
            out.appendSlice(c.a, "module unload") catch oom();
            wrote_unload = true;
        }
        out.appendSlice(c.a, str(c.a, " {s}", .{q(c.a, module)})) catch oom();
    }
    if (wrote_unload) out.append(c.a, '\n') catch oom();
    return out.items;
}

const record_active_modules =
    \\EB_LOCAL_DEV_SAVED=$(printf '%s\nactive:%s' "$eb_local_dev_saved_base" "${LOADEDMODULES-}")
    \\unset eb_local_dev_saved_base
    \\export EB_LOCAL_DEV_SAVED
    \\
;

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
    if (g.replace and (g.lock or g.locked))
        die("dev --replace does not go with --lock or --locked", .{});
    if (g.locked) {
        if (extra.len > 0) die("dev --locked loads the modules of {s}; name none on the line", .{lock_name});
        if (g.envrc) return writeEnvrc(c, replay(a, "dev", s, g, installed.prefix, extra));
        return lockedLines(c, s, g, installed);
    }
    if (g.envrc) return writeEnvrc(c, replay(a, "dev", s, g, installed.prefix, extra));
    if (!g.json_out and !g.lock) evalHint(replay(a, "dev", s, g, installed.prefix, extra));
    var out: std.ArrayList(u8) = .empty;
    const setup = if (g.replace) replacePrelude(c, currentDevSaved(c)) else "";
    out.appendSlice(a, environmentLines(c, s, installed, g.pure, setup)) catch oom();
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
    out.appendSlice(a, installed_rpath_settings) catch oom();
    out.appendSlice(a, host_ca_bundle) catch oom();
    // A program linked here belongs to this shell's CPU (and GPU) target, so
    // its install directory names them; the shell fills them in once EESSI
    // has picked them.
    const dev_root = std.fs.path.join(a, &.{ installed.prefix, "dev" }) catch oom();
    out.appendSlice(a, str(a, "export EB_LOCAL_DEV_PREFIX={s}\"/${{EESSI_VERSION-}}/${{EESSI_SOFTWARE_SUBDIR-}}${{EESSI_ACCELERATOR_TARGET:+/$EESSI_ACCELERATOR_TARGET}}\"\n", .{q(a, dev_root)})) catch oom();
    // Same bytes as eb: src/cargo-linker.sh, embedded as extend.cargo_linker.
    out.appendSlice(a, extend.cargo_linker) catch oom();
    out.appendSlice(a, dev_lang_dirs) catch oom();
    if (g.replace) out.appendSlice(a, record_active_modules) catch oom();
    const lines = emittedLines(a, envStrict(c, g), out.items);
    if (g.lock) return writeLock(c, s, lines);
    if (g.json_out) return emitEnvChange(c, "dev", lines);
    if (!emit(lines)) return 1;
    if (!g.pure and nonEmpty(c.env.get("LD_LIBRARY_PATH")) != null) {
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

/// Build-system settings that preserve run paths supplied by compiler
/// wrappers when a project is installed.
const installed_rpath_settings =
    \\case " ${CMAKE_ARGS-} " in
    \\    *" -DCMAKE_SKIP_RPATH="* | *" -DCMAKE_SKIP_RPATH:"*) ;;
    \\    *) CMAKE_ARGS="-DCMAKE_SKIP_RPATH=ON${CMAKE_ARGS:+ $CMAKE_ARGS}" ;;
    \\esac
    \\export CMAKE_ARGS
    \\EB_LOCAL_MESON_INSTALL_RPATH=
    \\_eb_local_seen=:
    \\_eb_local_eprefix=${EESSI_EPREFIX-}
    \\while [[ $_eb_local_eprefix == *//* ]]; do _eb_local_eprefix=${_eb_local_eprefix//\/\//\/}; done
    \\while [ "${_eb_local_eprefix%/}" != "$_eb_local_eprefix" ] && [ "$_eb_local_eprefix" != / ]; do _eb_local_eprefix=${_eb_local_eprefix%/}; done
    \\_eb_local_rest=${LIBRARY_PATH-}:
    \\while [ -n "$_eb_local_rest" ]; do
    \\    _eb_local_dir=${_eb_local_rest%%:*}
    \\    _eb_local_rest=${_eb_local_rest#*:}
    \\    while [[ $_eb_local_dir == *//* ]]; do _eb_local_dir=${_eb_local_dir//\/\//\/}; done
    \\    while [ "${_eb_local_dir%/}" != "$_eb_local_dir" ] && [ "$_eb_local_dir" != / ]; do _eb_local_dir=${_eb_local_dir%/}; done
    \\    case $_eb_local_dir in /?*) ;; *) continue ;; esac
    \\    case $_eb_local_dir in *,* | *:*) continue ;; esac
    \\    case $_eb_local_dir in /lib | /lib/* | /lib64 | /lib64/* | /usr | /usr/*) continue ;; esac
    \\    if [ -n "$_eb_local_eprefix" ]; then
    \\        case $_eb_local_dir in "$_eb_local_eprefix" | "$_eb_local_eprefix"/*) continue ;; esac
    \\    fi
    \\    case $_eb_local_seen in *":$_eb_local_dir:"*) continue ;; esac
    \\    _eb_local_seen=$_eb_local_seen$_eb_local_dir:
    \\    EB_LOCAL_MESON_INSTALL_RPATH=${EB_LOCAL_MESON_INSTALL_RPATH:+$EB_LOCAL_MESON_INSTALL_RPATH:}$_eb_local_dir
    \\done
    \\export EB_LOCAL_MESON_INSTALL_RPATH
    \\unset _eb_local_seen _eb_local_eprefix _eb_local_rest _eb_local_dir
    \\
;

/// Propagate an rpath wrapper failure through the shell function that applies
/// generated dev lines, so later exports do not report a successful dev.
fn rpathEval(a: Allocator, command: []const u8) []const u8 {
    return str(a, "_eb_local_wrap=$({s}) || return $?\neval \"$_eb_local_wrap\"\nunset _eb_local_wrap\n", .{command});
}

fn familyDetectLines(a: Allocator) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "eb_local_family=gcc\n") catch oom();
    for (config.families) |f|
        out.appendSlice(a, str(a, "if [ -n \"${{{s}-}}\" ]; then eb_local_family={s}; fi\n", .{ f.ebroot, f.name })) catch oom();
    return out.items;
}

/// The lines that load the build environment. A dev.buildenv the caller
/// chose is loaded as it is. The default depends on the compilers the
/// modules brought in, which only the shell knows after it loads them: the
/// family's buildenv when Lmod has it, else the one at the compiler's own
/// toolchain level (buildenv/default-NVHPC-26.9) when the site installed
/// that, else the GCC one for CUDA (nvcc links through gcc), else eb-local's
/// RPATH wrappers, so nothing links without run paths. A family the site set
/// to "none" goes to the wrappers without asking Lmod. Whichever loads, a clang that no wrapper covers then
/// gets one: the LLVM module sets EBROOTLLVM, not llvm-compilers' variable,
/// so its clang comes with the GCC build environment, which does not wrap it.
fn buildenvLines(c: Ctx, s: config.Settings) []const u8 {
    const a = c.a;
    const gcc = q(a, s.dev_buildenv.value);
    var exe_buf: [sys.path_max]u8 = undefined;
    const exe = q(a, selfExe(&exe_buf) orelse tool);
    const unwrapped = rpathEval(a, str(a, "{s} rpath-wrappers --unwrapped", .{exe}));
    const pin_python =
        \\if [ "${EB_LOCAL_PIN_BUILDENV_PYTHON-}" = 1 ] && [ -x "${EPREFIX-}/usr/bin/python3" ]; then
        \\    _eb_local_python_root=${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}
        \\    _eb_local_python_dir=$_eb_local_python_root/eb-local/python-pin
        \\    if mkdir -p "$_eb_local_python_dir" && chmod 700 "$_eb_local_python_dir"; then
        \\        if ln -sfn "$EPREFIX/usr/bin/python3" "$_eb_local_python_dir/python3"; then
        \\            case $PATH in "$_eb_local_python_dir"|"$_eb_local_python_dir":*) ;; *) PATH="$_eb_local_python_dir:$PATH" ;; esac
        \\            export PATH
        \\        else
        \\            echo "eb-local: cannot pin build environment Python" >&2
        \\        fi
        \\    else
        \\        echo "eb-local: cannot create a private Python wrapper directory" >&2
        \\    fi
        \\    unset _eb_local_python_root _eb_local_python_dir
        \\fi
        \\
    ;
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default")) return str(a, "module load {s}\n{s}{s}", .{ gcc, pin_python, unwrapped });
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    add(a, &out, familyDetectLines(a));
    add(a, &out, "case $eb_local_family in\n");
    for (config.families, s.buildenv_for) |f, b| {
        // "none" from a site or the environment means the wrappers, with no
        // level build environment tried; the built-in "none" (NVHPC) does try.
        const refused = b.value.len == 0 and !std.mem.eql(u8, b.from, "default");
        const level = if (f.compiler.len == 0 or refused)
            "''"
        else
            str(a, "${{{s}:+buildenv/default-{s}-${s}}}", .{ f.version, f.compiler, f.version });
        add(a, &out, str(a, "    {s}) eb_local_buildenv={s} eb_local_level={s} ;;\n", .{ f.name, if (b.value.len == 0) "''" else q(a, b.value), level }));
    }
    add(a, &out, "    *) eb_local_buildenv= eb_local_level= ;;\nesac\n");
    add(a, &out, str(a,
        \\if [ "$eb_local_family" = gcc ]; then
        \\    module load {s}
        \\elif [ -n "$eb_local_buildenv" ] && module is-avail "$eb_local_buildenv" >/dev/null 2>&1; then
        \\    module load "$eb_local_buildenv"
        \\elif [ -n "$eb_local_level" ] && module is-avail "$eb_local_level" >/dev/null 2>&1; then
        \\    module load "$eb_local_level"
        \\elif [ "$eb_local_family" = cuda ]; then
        \\    module load {s}
        \\else
        \\    {s}
        \\fi
        \\unset eb_local_family eb_local_buildenv eb_local_level
        \\
    , .{ gcc, gcc, rpathEval(a, str(a, "{s} rpath-wrappers --for \"$eb_local_family\"", .{exe})) }));
    add(a, &out, pin_python);
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
    return if (emit(str(a, "export PATH={s}:\"$PATH\"\nexport EB_LOCAL_RPATH_WRAPPERS={s}\n", .{ q(a, dir), q(a, dir) }))) 0 else 1;
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

const CheckQueueItem = struct {
    path: []const u8,
    loader_root: ?[]const u8 = null,
    inherited_rpath: []const []const u8 = &.{},
};

const Check = struct {
    problems: usize = 0,
    json: bool = false,
    recursive: bool = false,
    files: std.ArrayList(CheckFileJson) = .empty,
    audited: std.StringHashMapUnmanaged(void) = .empty,
    queued: std.StringHashMapUnmanaged(void) = .empty,
    queue: std.ArrayList(CheckQueueItem) = .empty,

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

    fn enqueue(k: *Check, a: Allocator, path: []const u8, loader_root: ?[]const u8, inherited_rpath: []const []const u8) void {
        if (!k.recursive) return;
        const key = canonicalKey(a, path);
        if (k.audited.contains(key) or k.queued.contains(key)) return;
        k.queued.put(a, key, {}) catch oom();
        k.queue.append(a, .{
            .path = a.dupe(u8, path) catch oom(),
            .loader_root = loader_root,
            .inherited_rpath = inherited_rpath,
        }) catch oom();
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
fn reportElf(
    c: Ctx,
    k: *Check,
    path: []const u8,
    elf: elfcheck.Elf,
    quiet: bool,
    inherited_loader_root: ?[]const u8,
    inherited_rpath: []const []const u8,
) void {
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

    // Inherited DT_RPATH from loading executables applies after this object's
    // own DT_RPATH when this object has no DT_RUNPATH, matching ld.so scope.
    var child_rpath_list: std.ArrayList([]const u8) = .empty;
    if (elf.runpath == null) {
        for (sr.dirs.items, sr.whence.items) |d, why| {
            if (std.mem.eql(u8, why, "RPATH")) child_rpath_list.append(a, d) catch oom();
        }
        // ld.so reads the loaders' DT_RPATH right after the object's own and
        // before LD_LIBRARY_PATH, so they go in at that place, not at the end:
        // a library both lists hold is then found where the loader finds it.
        var at: usize = 0;
        while (at < sr.whence.items.len and std.mem.eql(u8, sr.whence.items[at], "RPATH")) at += 1;
        for (inherited_rpath) |d| {
            sr.dirs.insert(a, at, d) catch oom();
            sr.whence.insert(a, at, "RPATH") catch oom();
            at += 1;
            child_rpath_list.append(a, d) catch oom();
        }
    } else {
        for (inherited_rpath) |d| child_rpath_list.append(a, d) catch oom();
    }

    // The loader's own directories: <root>/lib64 and the rest, where
    // <root> is the compatibility layer for its loader, / for the host's.
    // Shared objects inherit the loading executable's loader root when they
    // have no PT_INTERP of their own.
    const effective_loader_root: ?[]const u8 = if (elf.interp) |i|
        elfcheck.loaderRoot(i)
    else if (inherited_loader_root) |lr|
        lr
    else
        eprefix;
    const root = effective_loader_root orelse "/";
    for (loaderDirs(a, root)) |d| {
        sr.dirs.append(a, d) catch oom();
        sr.whence.append(a, "the loader's directories") catch oom();
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
                k.problem(a, "NEEDED library {s} cannot be resolved for {s}", .{ n, path });
            } else k.enqueue(a, needed_path, effective_loader_root, child_rpath_list.items);
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
                k.problem(a, "NEEDED library {s} cannot be resolved for {s}", .{ n, path });
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
        k.enqueue(a, h.path, effective_loader_root, child_rpath_list.items);
    }
}

/// Open `path` and report it. A tree audit (`skip_non_elf`) skips a file
/// that is not 64-bit little-endian ELF; naming the file does not.
/// True when an ELF file was audited.
fn auditFile(
    c: Ctx,
    k: *Check,
    path: []const u8,
    quiet: bool,
    skip_non_elf: bool,
    unreadable: *bool,
    inherited_loader_root: ?[]const u8,
    inherited_rpath: []const []const u8,
) bool {
    const opened = fsx.openRegular(fsx.cwd, path, !skip_non_elf) catch |e| {
        warn("cannot open {s} ({s})", .{ path, storage.describeError(e) });
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
    reportElf(c, k, path, elf, quiet or k.json, inherited_loader_root, inherited_rpath);
    return true;
}

fn drainCheckQueue(c: Ctx, k: *Check, quiet: bool, unreadable: *bool, elfs: *usize) void {
    var idx: usize = 0;
    while (idx < k.queue.items.len) : (idx += 1) {
        const item = k.queue.items[idx];
        if (k.isAudited(c.a, item.path)) continue;
        if (auditFile(c, k, item.path, quiet, false, unreadable, item.loader_root, item.inherited_rpath)) elfs.* += 1;
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
        if (auditFile(c, &k, f, quiet, false, &unreadable, null, &.{})) elfs += 1;
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
        warn("cannot open {s} ({s})", .{ root, storage.describeError(e) });
        unreadable.* = true;
        return;
    };
    defer sys.close(fd);
    var names: std.ArrayList([]const u8) = .empty;
    var it = fsx.DirIter.init(c.a, fd) catch oom();
    while (true) {
        const entry = it.next() catch |e| {
            warn("cannot read {s} ({s})", .{ root, storage.describeError(e) });
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
            warn("cannot stat {s} ({s})", .{ path, storage.describeError(e) });
            unreadable.* = true;
            continue;
        };
        if (st.isLink()) continue;
        const path = std.fs.path.join(c.a, &.{ root, name }) catch oom();
        if (st.isDir()) {
            walkElfs(c, path, quiet, k, unreadable, elfs, depth + 1);
        } else if (st.isReg()) {
            if (auditFile(c, k, path, quiet, true, unreadable, null, &.{})) elfs.* += 1;
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
    row(&settings, a, json, "storage.mode", @tagName(s.storage_mode.value), s.storage_mode.from);
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
    return if (emit(out.items)) 0 else 1;
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
        if (!config.validNodeTypeName(name)) die("unknown configuration key '{s}'", .{key});
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
        if (!config.validSecretName(name)) die("unknown configuration key '{s}'", .{key});
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
        return if (emit(text)) 0 else 1;
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
    if (comptime build_options.test_ops) {
        if (storage.takeWriteErrno()) |e|
            die("cannot write {s}: {s}", .{ target, sys.describeErrno(e) });
    }
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
    /// The process group was still occupied when the SIGKILL deadline
    /// passed. Callers must not clean logs as though it had been reaped.
    unreaped,
};

/// An exit code as it is. A signal is raised again, with the disposition this
/// process was started with: the default kills the process, so a shell and
/// Slurm see the signal rather than exit 128+n and carry on, and an ignored
/// signal (nohup) stays ignored.
fn stop(run: Run) u8 {
    switch (run) {
        .exit => |c| return c,
        .unreaped => return 1,
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

/// The program being waited for, 0 for none, whether it leads a dedicated
/// non-TTY process group, and the first signal of `passed_on` received while
/// a `Guard` was held. Atomics only: the handler can run between any two
/// instructions.
var waited_pid = std.atomic.Value(linux.pid_t).init(0);
var waited_pgroup = std.atomic.Value(bool).init(false);
var first_signal = std.atomic.Value(u32).init(0);

/// Grace deadline in milliseconds for cooperative descendants in a signalled
/// non-TTY process group to flush logs and exit on `SIGCHLD` before `SIGKILL`.
/// Half a second accommodates Python and Lua signal teardown without delaying
/// interactive cancellation past sub-second responsiveness when a descendant
/// ignores `SIGINT`, `SIGTERM`, or `SIGHUP`.
const group_settle_grace_ms: i64 = 500;
var test_group_grace_ms: i64 = 0;

/// How long to keep sending SIGKILL and reaping after the grace period.
/// This is the bound `proc.stopGroup` uses. A child in uninterruptible
/// sleep can sit with SIGKILL pending, and a blocking wait never
/// returns. A member forked after one signal can miss that signal.
/// Reaching this deadline without ECHILD is a timeout, not an empty group.
const group_kill_reap_ms: i64 = 10_000;

/// Pause between kill attempts, so a late fork is signalled again soon.
const group_kill_slice_ms: i64 = 10;

/// Most `wait4` calls in one `reapPending` pass. `EINTR` and a reaped pid
/// are retries. A signal storm or a stream of exiting children returns
/// `.busy` at this cap, or at the deadline, so the caller can pause.
const reap_pass_cap: u32 = 64;

fn monotonicMs() i64 {
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| {
            if (probe.clock) |clock| return clock.load(.acquire);
        }
    }
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Stand-in for `wait4(-pgid, WNOHANG)` and the group scan, compiled only
/// into a `-Dtest-ops` build. `phase` 0 makes `wait4` report a live child;
/// `phase` 1 makes it report `ECHILD`. While installed, the scan reports no
/// live member. `entered` is written once `settleGroup` commits to waiting,
/// and a byte on `wake` releases that wait. After the first `SIGKILL`,
/// `script` replaces `phase` one result at a time. `script_from_start`
/// uses `script` before that signal as well. `eintr` is `EINTR` and
/// `reaped` is a collected pid. Both are retries, so one pass may read
/// several of them. `clock`, when set, replaces the monotonic clock, and
/// `pauseUntil` jumps it to the wake time.
const ProbeStep = enum { live, empty, unknown, eintr, reaped };

const SettleProbe = struct {
    phase: *std.atomic.Value(u8),
    entered: i32,
    wake: i32,
    told: std.atomic.Value(u8) = .init(0),
    /// When false, the grace loop keeps its own deadline instead of
    /// blocking on `wake`. `phase` still stands in for `wait4`.
    hold: bool = true,
    /// Skip the grace wait and go straight to SIGKILL.
    force_kill: bool = false,
    /// `wait4` results after the first SIGKILL, in order. Empty keeps `phase`.
    /// The last entry repeats. `eintr` and `reaped` stay in the reap loop.
    script: []const ProbeStep = &.{},
    /// Apply `script` to the grace reaps as well, before the first SIGKILL.
    script_from_start: bool = false,
    script_i: std.atomic.Value(u32) = .init(0),
    /// SIGKILL calls that returned something other than EINTR.
    kills: std.atomic.Value(u32) = .init(0),
    /// Block inside the post-kill reap with this 1-based index until
    /// `release` is set. 0 disables the barrier.
    barrier_at: u32 = 0,
    release: std.atomic.Value(u8) = .init(0),
    /// 0 off, 1 armed, 2 consumed. Armed turns the next scripted empty
    /// result into one live result: a member forked after SIGKILL.
    late: std.atomic.Value(u8) = .init(0),
    /// SIGKILL count when that late member was observed.
    kills_at_fork: std.atomic.Value(u32) = .init(0),
    /// Times an unexpected reap errno was reported.
    reported: std.atomic.Value(u32) = .init(0),
    /// Times the kill deadline passed on a live child or a busy reap.
    timeouts: std.atomic.Value(u32) = .init(0),
    /// Override `group_settle_grace_ms` when non-negative. `force_kill` wins.
    grace_ms: i64 = -1,
    /// Override `group_kill_reap_ms` when positive.
    kill_ms: i64 = 0,
    /// Monotonic milliseconds. Null uses the real clock.
    clock: ?*std.atomic.Value(i64) = null,
    /// `wait4` reads observed through the probe.
    wait_calls: std.atomic.Value(u32) = .init(0),
    /// Most `wait4` reads inside one `reapPending` call.
    max_pass_waits: std.atomic.Value(u32) = .init(0),
    /// `wait4` reads in the latest `reapPending` call.
    last_pass_waits: std.atomic.Value(u32) = .init(0),
    /// `reapPending` calls that read `wait4` at least once.
    passes: std.atomic.Value(u32) = .init(0),
};

var settle_probe: ?*SettleProbe = null;
var settle_entered_fd: i32 = -1;

fn noteSettleEntered() void {
    if (settle_entered_fd < 0) return;
    _ = linux.write(settle_entered_fd, "e", 1);
}

const Reap = union(enum) {
    /// `wait4` returned ECHILD: no matching child remains.
    empty,
    /// A child of this process is still in the group.
    live,
    /// `wait4` failed with an errno other than EINTR or ECHILD.
    unknown: linux.E,
    /// The pass stopped on `EINTR` or a reaped pid. The cap or the
    /// deadline was reached, and the group is not drained.
    busy,
};

const GroupEnd = enum { drained, timed_out };

/// One `wait4` result. `.retry` is a reaped zombie or EINTR; the caller
/// calls `wait4` again. Only ECHILD is an empty group.
const WaitRead = union(enum) { retry, reap: Reap };

fn readWait(rc: usize) WaitRead {
    switch (linux.errno(rc)) {
        .SUCCESS => {
            if (rc == 0) return .{ .reap = .live };
            return .retry;
        },
        .INTR => return .retry,
        .CHILD => return .{ .reap = .empty },
        else => |e| return .{ .reap = .{ .unknown = e } },
    }
}

fn probeForceKill() bool {
    if (comptime !build_options.test_ops) return false;
    const probe = settle_probe orelse return false;
    return probe.force_kill;
}

fn probeUsesScript(probe: *SettleProbe) bool {
    if (probe.script.len == 0) return false;
    if (probe.script_from_start) return true;
    return probe.kills.load(.acquire) != 0;
}

fn probeRead(probe: *SettleProbe) WaitRead {
    const seen = probe.wait_calls.fetchAdd(1, .monotonic);
    // A retry script that ignored the cap would spin. Stop so the test
    // fails instead of hanging.
    if (seen >= 1_000_000) return .{ .reap = .empty };
    if (!probeUsesScript(probe)) {
        const reap: Reap = if (probe.phase.load(.acquire) == 0) .live else .empty;
        return .{ .reap = reap };
    }
    const n = probe.script.len;
    const i = probe.script_i.fetchAdd(1, .acq_rel);
    var step: ProbeStep = if (i < n) probe.script[i] else probe.script[n - 1];
    if (step == .empty and probe.late.load(.acquire) == 1) {
        if (probe.late.cmpxchgStrong(1, 2, .acq_rel, .acquire) == null) {
            probe.kills_at_fork.store(probe.kills.load(.acquire), .release);
            step = .live;
        }
    }
    if (probe.barrier_at != 0 and i + 1 == probe.barrier_at) {
        _ = linux.write(probe.entered, "b", 1);
        while (probe.release.load(.acquire) == 0) {
            var pfd = [1]linux.pollfd{.{ .fd = probe.wake, .events = linux.POLL.IN, .revents = 0 }};
            if (linux.errno(linux.poll(&pfd, 1, 1000)) == .INTR) continue;
        }
        var drain = [1]linux.pollfd{.{ .fd = probe.wake, .events = linux.POLL.IN, .revents = 0 }};
        const got = linux.poll(&drain, 1, 0);
        if (linux.errno(got) == .SUCCESS and got > 0) {
            var buf: [16]u8 = undefined;
            while (linux.errno(linux.read(probe.wake, &buf, buf.len)) == .INTR) {}
        }
    }
    return switch (step) {
        .live => .{ .reap = .live },
        .empty => .{ .reap = .empty },
        .unknown => .{ .reap = .{ .unknown = .IO } },
        .eintr, .reaped => .retry,
    };
}

fn nextWait(pgid: linux.pid_t, raw: *i32) WaitRead {
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| return probeRead(probe);
    }
    return readWait(linux.wait4(-pgid, raw, linux.W.NOHANG, null));
}

fn noteReapPass(calls: u32) void {
    if (comptime !build_options.test_ops) return;
    const probe = settle_probe orelse return;
    _ = probe.passes.fetchAdd(1, .monotonic);
    probe.last_pass_waits.store(calls, .monotonic);
    const prev = probe.max_pass_waits.load(.monotonic);
    if (calls > prev) probe.max_pass_waits.store(calls, .monotonic);
}

/// Reap zombies in `pgid` without blocking. One pass calls `wait4` at
/// most `reap_pass_cap` times. After `EINTR` and after each reaped pid
/// it checks `deadline`. The cap or the deadline returns `.busy`, which
/// is not an empty group.
fn reapPending(pgid: linux.pid_t, deadline: i64) Reap {
    if (pgid <= 0) return .empty;
    var calls: u32 = 0;
    var raw: i32 = 0;
    var result: Reap = .busy;
    while (calls < reap_pass_cap) {
        calls += 1;
        switch (nextWait(pgid, &raw)) {
            .reap => |r| {
                result = r;
                break;
            },
            .retry => if (monotonicMs() >= deadline) break,
        }
    }
    noteReapPass(calls);
    return result;
}

/// Report an unexpected `wait4` errno once per settle. EINTR is retried in
/// `readWait` and is not an unknown result.
fn noteUnknown(noted: *bool, pgid: linux.pid_t, reap: Reap) void {
    const err = switch (reap) {
        .unknown => |e| e,
        else => return,
    };
    if (noted.*) return;
    noted.* = true;
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| _ = probe.reported.fetchAdd(1, .monotonic);
    }
    // A test binary's stderr is captured, and zig build prints "failed
    // command" for that capture even when every test passed.
    if (@import("builtin").is_test) return;
    warn("cannot reap process group {d} ({s})", .{ pgid, sys.describeErrno(err) });
}

/// Reap exited children in `pgid` in bounded passes. True only when a
/// child of this process is still in `pgid`. A pass that returns `.busy`
/// pauses and tries again until `ECHILD`, a live child, an unexpected
/// errno, or the deadline.
fn reapGroupState(pgid: linux.pid_t) bool {
    const deadline = monotonicMs() + group_kill_reap_ms;
    while (true) {
        const reap = reapPending(pgid, deadline);
        if (reap == .live) return true;
        if (reap != .busy) return false;
        if (monotonicMs() >= deadline) return false;
        pauseUntil(null, @min(deadline, monotonicMs() + group_kill_slice_ms));
    }
}

fn settleScan(pgid: linux.pid_t) bool {
    if (comptime build_options.test_ops) {
        if (settle_probe != null) return false;
    }
    return proc.groupAlive(pgid);
}

/// Block until the test releases the probe. True when the probe handled the
/// wait, so the caller checks `wait4` again. A probe with `hold` false
/// does not handle it, and the caller waits out the grace deadline.
fn probeWait() bool {
    if (comptime !build_options.test_ops) return false;
    const probe = settle_probe orelse return false;
    if (!probe.hold) return false;
    if (probe.told.swap(1, .acq_rel) == 0) {
        _ = linux.write(probe.entered, "e", 1);
    }
    var pfd = [1]linux.pollfd{.{ .fd = probe.wake, .events = linux.POLL.IN, .revents = 0 }};
    while (linux.errno(linux.poll(&pfd, 1, -1)) == .INTR) {}
    var buf: [16]u8 = undefined;
    while (linux.errno(linux.read(probe.wake, &buf, buf.len)) == .INTR) {}
    return true;
}

fn drainSignalFd(sfd: sys.fd_t) void {
    var buf: [8 * @sizeOf(linux.signalfd_siginfo)]u8 align(@alignOf(linux.signalfd_siginfo)) = undefined;
    while (true) {
        const rc = linux.read(sfd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return,
            .INTR => continue,
            else => return,
        }
    }
}

/// Wait until `until` (monotonic milliseconds), or until `SIGCHLD` is
/// readable on `sfd`. `EINTR` retries. A failed poll sleeps instead, so a
/// missing signalfd cannot spin. A null `sfd` always sleeps, so a signal
/// storm cannot skip the pause between reap passes.
fn pauseUntil(sfd: ?sys.fd_t, until: i64) void {
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| {
            if (probe.clock) |clock| {
                const now = clock.load(.acquire);
                if (now < until) clock.store(until, .release);
                return;
            }
        }
    }
    while (true) {
        const rem = until - monotonicMs();
        if (rem <= 0) return;
        if (sfd) |fd| {
            var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, @intCast(rem));
            switch (linux.errno(rc)) {
                .INTR => continue,
                .SUCCESS => {
                    drainSignalFd(fd);
                    return;
                },
                else => {},
            }
        }
        const left = until - monotonicMs();
        if (left <= 0) return;
        const sec = @divTrunc(left, 1000);
        var ts: linux.timespec = .{
            .sec = @intCast(sec),
            .nsec = @intCast((left - sec * 1000) * 1_000_000),
        };
        if (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) continue;
        return;
    }
}

/// Send one SIGKILL, retrying EINTR until `deadline`. False means the
/// deadline passed during those retries. Other errnos count as one attempt:
/// the group may already be gone, and the following reap decides.
fn sendKill(pgid: linux.pid_t, deadline: i64) bool {
    while (true) {
        const kr = linux.kill(-pgid, .KILL);
        if (linux.errno(kr) != .INTR) {
            if (comptime build_options.test_ops) {
                if (settle_probe) |probe| _ = probe.kills.fetchAdd(1, .release);
            }
            return true;
        }
        if (monotonicMs() >= deadline) return false;
    }
}

fn killBudgetMs() i64 {
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| if (probe.kill_ms > 0) return probe.kill_ms;
    }
    return group_kill_reap_ms;
}

/// Send SIGKILL to process group `pgid` and reap until `wait4` returns
/// `ECHILD`, or the kill deadline passes. Each pass signals the group
/// again, so a member forked after the previous `SIGKILL` is killed too.
/// `wait4` does not block. `EINTR` or a reaped pid stops the pass at
/// `reap_pass_cap` or at the deadline and returns `.busy`. The loop
/// pauses before the next pass. The last reap result is kept. At the
/// deadline one more bounded reap runs. `ECHILD` is `.drained`. Anything
/// else is `.timed_out`: a diagnostic is printed, and the caller must
/// not clean logs or otherwise treat the group as empty.
fn reapKilledGroup(pgid: linux.pid_t, sfd: ?sys.fd_t, noted: *bool) GroupEnd {
    if (pgid <= 0) return .drained;
    const deadline = monotonicMs() + killBudgetMs();
    var last: Reap = .live;
    while (true) {
        if (!sendKill(pgid, deadline)) break;
        last = reapPending(pgid, deadline);
        if (last == .empty) return .drained;
        noteUnknown(noted, pgid, last);
        const now = monotonicMs();
        if (now >= deadline) break;
        const until = @min(deadline, now + group_kill_slice_ms);
        // A busy pass is a storm of `EINTR` or exiting children. Sleep
        // even when `SIGCHLD` is already readable, so the next pass does
        // not start at once.
        if (last == .busy) {
            pauseUntil(null, until);
        } else {
            pauseUntil(sfd, until);
        }
    }
    last = reapPending(pgid, deadline);
    if (last == .empty) return .drained;
    noteUnknown(noted, pgid, last);
    if (last == .live or last == .busy) noteLiveTimeout(pgid);
    return .timed_out;
}

fn noteLiveTimeout(pgid: linux.pid_t) void {
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| _ = probe.timeouts.fetchAdd(1, .monotonic);
    }
    // See noteUnknown: a passing test must not write this to stderr.
    if (@import("builtin").is_test) return;
    warn("a descendant is still in process group {d} after SIGKILL; it was not reaped", .{pgid});
}

fn graceBudgetMs() i64 {
    const override = test_group_grace_ms;
    if (comptime build_options.test_ops) {
        if (settle_probe) |probe| {
            if (probe.force_kill) return 0;
            if (probe.grace_ms >= 0) return probe.grace_ms;
        }
        if (override > 0) return override;
    }
    return group_settle_grace_ms;
}

/// Wait on `SIGCHLD` via `signalfd` and `poll` up to `group_settle_grace_ms`
/// for reparented descendants in `pgid` to exit, then `SIGKILL` and reap
/// until none remain or `group_kill_reap_ms` passes. Only `ECHILD` ends the
/// wait. Any other `wait4` error stays in that bounded retry. Each reap
/// pass stops at `reap_pass_cap` or at its deadline and returns `.busy`
/// rather than spinning. The grace loop pauses between those passes.
/// Grace expiry is not an empty group: it goes on to `SIGKILL`. The kill
/// deadline without `ECHILD` is `.timed_out`.
fn settleGroup(pgid: linux.pid_t) GroupEnd {
    if (pgid <= 0) return .drained;
    var noted = false;
    const skip_grace = probeForceKill();
    const grace_deadline = monotonicMs() + graceBudgetMs();
    // wait4 is authoritative for children of this process. The /proc scan
    // can miss a live member, and returning then orphans it when stop()
    // re-raises the signal. Only ECHILD means no child remains.
    const opened = reapPending(pgid, grace_deadline);
    noteUnknown(&noted, pgid, opened);
    if (opened == .empty and !settleScan(pgid)) return .drained;

    var chld = linux.sigemptyset();
    linux.sigaddset(&chld, .CHLD);
    var old_mask: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &chld, &old_mask);
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);

    const sfd_rc = linux.signalfd(-1, &chld, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
    const sfd: ?sys.fd_t = if (linux.errno(sfd_rc) == .SUCCESS) @intCast(sfd_rc) else null;
    defer if (sfd) |fd| sys.close(fd);
    noteSettleEntered();

    while (true) {
        if (sfd) |fd| drainSignalFd(fd);
        const pending = reapPending(pgid, grace_deadline);
        noteUnknown(&noted, pgid, pending);
        if (pending == .empty and !settleScan(pgid)) return .drained;
        if (skip_grace) break;
        const rem = grace_deadline - monotonicMs();
        if (rem <= 0) break;
        if (pending == .live and probeWait()) continue;
        if (pending == .live and sfd != null) {
            var pfd = [1]linux.pollfd{.{ .fd = sfd.?, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, @intCast(rem));
        } else {
            pauseUntil(null, @min(grace_deadline, monotonicMs() + group_kill_slice_ms));
        }
    }

    const after = reapPending(pgid, grace_deadline);
    noteUnknown(&noted, pgid, after);
    if (after == .empty and !settleScan(pgid)) return .drained;
    while (linux.errno(linux.kill(-pgid, .CONT)) == .INTR) {}
    return reapKilledGroup(pgid, sfd, &noted);
}

fn selfPgrp() linux.pid_t {
    const rc: isize = @bitCast(linux.getpgid(0));
    return if (rc > 0) @intCast(rc) else 0;
}

/// Whether standard input, output or error is a controlling terminal whose
/// foreground process group is `pgrp`.
fn isForegroundTty(pgrp: linux.pid_t) bool {
    if (pgrp <= 0) return false;
    for ([_]sys.fd_t{ 0, 1, 2 }) |fd| {
        var fg: linux.pid_t = 0;
        if (linux.errno(linux.ioctl(fd, linux.T.IOCGPGRP, @intFromPtr(&fg))) == .SUCCESS and fg == pgrp)
            return true;
    }
    return false;
}

fn passOn(sig: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = first_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
    // From the terminal, the signal reached the program too.
    if (info.code == si_kernel) return;
    const pid = waited_pid.load(.seq_cst);
    if (pid <= 0) return;
    if (waited_pgroup.load(.seq_cst)) {
        proc.killGroup(pid, sig);
        return;
    }
    const self_pid: linux.pid_t = @intCast(linux.getpid());
    if (info.code <= 0 and info.fields.common.first.piduid.pid == self_pid) return;
    const pgrp = selfPgrp();
    if (pgrp == self_pid) {
        proc.killGroup(pgrp, sig);
    } else {
        _ = linux.kill(pid, sig);
    }
}

/// Block `passed_on` while a guard is held, so that a signal is either seen
/// by the check that follows or comes after the step the check decides.
fn blockPassedOn() linux.sigset_t {
    var block = linux.sigemptyset();
    for (passed_on) |sig| linux.sigaddset(&block, sig);
    var prev: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &block, &prev);
    return prev;
}

fn restoreMask(prev: *const linux.sigset_t) void {
    _ = linux.sigprocmask(linux.SIG.SETMASK, prev, null);
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
    /// `error.ForkFailed` is a `fork` that did not start the program.
    fn run(g: *const Guard, a: Allocator, argv: []const []const u8, envp: proc.Envp) error{ForkFailed}!Run {
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
        const self_pgrp = selfPgrp();
        const own_group = !isForegroundTty(self_pgrp);
        var prev_subreaper: c_int = 0;
        const set_subreaper = own_group and
            linux.errno(linux.prctl(@backingInt(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&prev_subreaper), 0, 0, 0)) == .SUCCESS and
            prev_subreaper == 0 and
            linux.errno(linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0)) == .SUCCESS;
        defer if (set_subreaper) {
            _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 0, 0, 0, 0);
        };
        const pid: isize = @bitCast(linux.fork());
        if (pid == 0) {
            if (own_group) _ = linux.setpgid(0, 0);
            for (passed_on, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
            _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
            const rc = linux.execve(zargv[0].?, zargv.ptr, envp);
            cli.err("eb-local: cannot run {s} ({s})\n", .{ argv[0], sys.describeErrno(linux.errno(rc)) });
            linux.exit_group(127);
        }
        if (pid > 0) {
            if (own_group) _ = linux.setpgid(@intCast(pid), @intCast(pid));
            waited_pgroup.store(own_group, .seq_cst);
            waited_pid.store(@intCast(pid), .seq_cst);
        }
        _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
        if (pid < 0) return error.ForkFailed;
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
        waited_pgroup.store(false, .seq_cst);
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
        if (own_group) {
            if (g.received() != null or !linux.W.IFEXITED(status)) {
                // A timeout is not a reaped group. Returning the child's
                // status here would let the caller clean logs anyway.
                if (settleGroup(@intCast(pid)) == .timed_out) return .unreaped;
            } else {
                _ = reapGroupState(@intCast(pid));
            }
        }
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
    const ran = guard.run(a, argv, envp) catch die("cannot start {s}", .{argv[0]});
    return if (guard.received()) |sig| .{ .signal = sig } else ran;
}

fn envpOf(a: Allocator, map: *const std.process.Environ.Map) proc.Envp {
    var b: common.env.Builder = .init(a);
    var it = map.iterator();
    while (it.next()) |kv| b.set(kv.key_ptr.*, kv.value_ptr.*) catch oom();
    return b.envp() catch oom();
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

fn tmpdirUid(c: Ctx, actual: linux.uid_t) linux.uid_t {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_TMPDIR_UID"))) |v| return std.fmt.parseInt(linux.uid_t, v, 10) catch actual;
    }
    return actual;
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
            "that root or this program's owner owns with --config FILE or EB_LOCAL_CONFIG=FILE. To build deliberately on this machine, pass --workstation.", .{undone});
    var r: storage.Refusal = .{};
    const job_id = c.env.get("SLURM_JOB_ID") orelse "";
    const jr = storage.jobRoot(c.a, nodeLocal(s), job_id, userName(c, s, undone), mountinfoText(c), callerUid(c), &r) catch |e| switch (e) {
        error.Refused => die("{s}; {s}.\n  {s}.", .{ r.message, undone, r.fix }),
        error.OutOfMemory => oom(),
    };
    return jr.path;
}

fn slurmEnvironment(c: Ctx) bool {
    var it = c.env.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "SLURM_") and kv.value_ptr.*.len > 0) return true;
    }
    return false;
}

fn schedulerPresent(c: Ctx) bool {
    return slurmEnvironment(c) or (proc.which(c.a, "sbatch", c.env.get("PATH") orelse "") catch null) != null;
}

fn localStorage(s: config.Settings, c: Ctx, g: Global) bool {
    return g.workstation or s.storage_mode.value == .local or !schedulerPresent(c);
}

fn localFilesystemAllowed(c: Ctx, s: config.Settings, path: []const u8) bool {
    const m = storage.mountOf(c.a, mountinfoText(c), path) catch oom() orelse return false;
    if (std.mem.eql(u8, m.fstype, "tmpfs") or std.mem.eql(u8, m.fstype, "ramfs"))
        return false;
    if (std.mem.eql(u8, storage.workspaceClass(path, m.fstype, s.shared_scratch.value), "shared"))
        return false;
    for (s.shared_scratch.value) |shared| {
        const canonical_shared = storage.canonical(c.a, shared, c.cwd) catch oom();
        if (storage.under(path, canonical_shared)) return false;
    }
    return true;
}

const PrivateChild = union(enum) {
    fd: sys.fd_t,
    missing,
    refused: []const u8,
};

fn openPrivateChild(c: Ctx, parent: sys.fd_t, name: []const u8, path: []const u8, create: bool) PrivateChild {
    var made = false;
    if (fsx.statAt(parent, name, false)) |st| {
        if (st.isLink()) return .{ .refused = str(c.a, "workstation workspace parent {s} is a symbolic link", .{path}) };
    } else |e| switch (e) {
        error.NotFound => {
            if (!create) return .missing;
            var zbuf: [sys.path_max:0]u8 = undefined;
            const zname = sys.z(&zbuf, name) catch return .{ .refused = str(c.a, "workstation workspace parent {s} is too long", .{path}) };
            const previous: linux.mode_t = @intCast(linux.syscall1(.umask, 0));
            const rc = linux.mkdirat(parent, zname.ptr, 0o700);
            _ = linux.syscall1(.umask, previous);
            if (sys.result(rc)) |_| made = true else |se| if (se != error.Exists)
                return .{ .refused = str(c.a, "cannot create workstation workspace parent {s} ({s})", .{ path, storage.describeError(se) }) };
        },
        else => return .{ .refused = str(c.a, "cannot inspect workstation workspace parent {s} ({s})", .{ path, storage.describeError(e) }) },
    }
    const fd = sys.openat(parent, name, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |e|
        return .{ .refused = str(c.a, "cannot securely open workstation workspace parent {s} ({s})", .{ path, storage.describeError(e) }) };
    const st = fsx.fstat(fd) catch |e| {
        sys.close(fd);
        return .{ .refused = str(c.a, "cannot inspect workstation workspace parent {s} ({s})", .{ path, storage.describeError(e) }) };
    };
    if (!st.isDir() or st.uid != callerUid(c) or st.mode & 0o022 != 0) {
        sys.close(fd);
        return .{ .refused = str(c.a, "workstation workspace parent {s} must be a directory you own and must not be writable by group or others", .{path}) };
    }
    if (made or st.perm() != 0o700) sys.fchmod(fd, 0o700) catch |e| {
        sys.close(fd);
        return .{ .refused = str(c.a, "cannot make workstation workspace parent {s} private ({s})", .{ path, storage.describeError(e) }) };
    };
    return .{ .fd = fd };
}

const LocalRoot = struct {
    path: []const u8,
    capacity_path: []const u8,
    refused_fstype: ?[]const u8 = null,
    refused_reason: ?[]const u8 = null,
};

/// Select and securely validate every eb-local-owned workspace parent.
/// Doctor calls this with create=false; builds call it with create=true.
fn checkedLocalRoot(c: Ctx, s: config.Settings, undone: []const u8, create: bool) LocalRoot {
    const a = c.a;
    var base: ?[]const u8 = null;
    var first: []const u8 = "eb-local";
    if (nonEmpty(c.env.get("TMPDIR"))) |tmp| {
        if (std.fs.path.isAbsolute(tmp)) {
            if (fsx.statAt(fsx.cwd, tmp, false)) |st| {
                const owner = tmpdirUid(c, st.uid);
                const owner_ok = owner == callerUid(c) or owner == 0;
                const writable_ok = st.mode & 0o022 == 0 or st.mode & 0o1000 != 0;
                if (st.isDir() and owner_ok and writable_ok) {
                    const canonical_tmp = storage.canonical(a, tmp, c.cwd) catch oom();
                    if (localFilesystemAllowed(c, s, canonical_tmp)) {
                        base = canonical_tmp;
                        first = std.fmt.allocPrint(a, "eb-local-{d}", .{callerUid(c)}) catch oom();
                    }
                }
            } else |_| {}
        }
    }
    if (base == null) {
        const cache = rpath.cacheHome(a, c.env) catch
            die("a workstation build needs an absolute XDG_CACHE_HOME or HOME; {s}.", .{undone});
        if (create) common.atomic.makedirs(cache) catch |e|
            die("cannot create workstation cache directory {s} ({s}); {s}.", .{ cache, storage.describeError(e), undone });
        base = storage.canonical(a, cache, c.cwd) catch oom();
    }
    const first_path = std.fs.path.join(a, &.{ base.?, first }) catch oom();
    const root = std.fs.path.join(a, &.{ first_path, "work" }) catch oom();
    if (!localFilesystemAllowed(c, s, base.?)) {
        const m = storage.mountOf(a, mountinfoText(c), base.?) catch oom();
        if (!create) return .{
            .path = root,
            .capacity_path = nearestExistingParent(base.?),
            .refused_fstype = if (m) |mount| mount.fstype else "an unknown file system",
        };
        die("workstation workspace directory {s} is on {s}, which is memory-backed, network or shared storage; {s}.\n" ++
            "  Set XDG_CACHE_HOME to a directory on this workstation's local disk.", .{ base.?, if (m) |mount| mount.fstype else "an unknown file system", undone });
    }
    if (!create) {
        if (fsx.statAt(fsx.cwd, base.?, false)) |_| {} else |_| {
            return .{ .path = root, .capacity_path = nearestExistingParent(base.?) };
        }
    }
    const base_fd = sys.openat(fsx.cwd, base.?, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch |e| {
        const why = str(a, "cannot open workstation workspace directory {s} ({s})", .{ base.?, storage.describeError(e) });
        if (!create) return .{ .path = root, .capacity_path = nearestExistingParent(base.?), .refused_reason = why };
        die("{s}; {s}.", .{ why, undone });
    };
    defer sys.close(base_fd);
    const first_result = openPrivateChild(c, base_fd, first, first_path, create);
    const first_fd = switch (first_result) {
        .fd => |fd| fd,
        .missing => return .{ .path = std.fs.path.join(a, &.{ first_path, "work" }) catch oom(), .capacity_path = base.? },
        .refused => |why| {
            if (!create) return .{ .path = root, .capacity_path = base.?, .refused_reason = why };
            die("{s}; {s}.", .{ why, undone });
        },
    };
    defer sys.close(first_fd);
    const work_result = openPrivateChild(c, first_fd, "work", root, create);
    const work_fd = switch (work_result) {
        .fd => |fd| fd,
        .missing => return .{ .path = root, .capacity_path = first_path },
        .refused => |why| {
            if (!create) return .{ .path = root, .capacity_path = first_path, .refused_reason = why };
            die("{s}; {s}.", .{ why, undone });
        },
    };
    sys.close(work_fd);
    return .{ .path = root, .capacity_path = root };
}

fn nearestExistingParent(path: []const u8) []const u8 {
    var current = path;
    while (true) {
        if (fsx.statAt(fsx.cwd, current, false)) |st| {
            if (st.isDir()) return current;
        } else |_| {}
        if (std.mem.eql(u8, current, "/")) return "/";
        current = std.fs.path.dirname(current) orelse "/";
    }
}

fn checkedWorkspaceRoot(c: Ctx, s: config.Settings, g: Global, undone: []const u8) []const u8 {
    return if (localStorage(s, c, g)) checkedLocalRoot(c, s, undone, true).path else checkedJobRoot(c, s, undone);
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

/// The prefix lock file is made when a command first takes the lock. One that
/// is there and is not a regular file would stop the command only after its
/// list is out, so it is refused before anything is written.
fn refuseIrregularPrefixLock(c: Ctx, prefix: []const u8) void {
    const lock_path = std.fs.path.join(c.a, &.{ prefix, ".eb-local", ".lock" }) catch oom();
    const st = fsx.statAt(fsx.cwd, lock_path, false) catch return;
    if (!st.isReg()) die("cannot lock {s}: not a regular file", .{lock_path});
}

fn prefixLockPath(c: Ctx, prefix: []const u8) []const u8 {
    return std.fs.path.join(c.a, &.{ prefix, ".eb-local", ".lock" }) catch oom();
}

/// Release `lock`, the lock file at `lock_path`, at the end of a command
/// that exits `code`. After a success a failed release is reported with
/// its errno and the command exits 1. After a failure, a failed write to
/// standard output among them, it is dropped and `sys.last_errno` is put
/// back, so the failure already reported stands.
fn endLock(code: u8, lock: *?sys.fd_t, lock_path: []const u8) u8 {
    if (code != 0 or stdout.failed) {
        storage.releaseLockAfterError(lock);
        return if (code != 0) code else 1;
    }
    storage.releaseLock(lock) catch |e| {
        warn("cannot release the lock on {s}: {s}", .{ lock_path, sys.describe(e) });
        return 1;
    };
    return 0;
}

fn acquirePrefixLock(c: Ctx, prefix: []const u8) ?sys.fd_t {
    const a = c.a;
    var err_msg: []const u8 = "";
    const timeout_ms = storage.lockTimeoutMs(c.env, &err_msg) orelse die("{s}", .{err_msg});
    const dir = std.fs.path.join(a, &.{ prefix, ".eb-local" }) catch oom();
    common.atomic.makedirs(dir) catch |e| die("cannot create {s} ({s})", .{ dir, sys.describe(e) });
    const lock_path = prefixLockPath(c, prefix);
    return switch (storage.acquireBoundedLock(a, lock_path, timeout_ms, true, &err_msg)) {
        .held => |fd| fd,
        .unlocked => null,
        .failed => die("{s}", .{err_msg}),
    };
}

/// The stop when the checked node-local mount takes no workspace.
fn workspaceFailed(a: Allocator, job_root: []const u8, e: anyerror) noreturn {
    if (e == error.OutOfMemory) oom();
    die("cannot make a build workspace in {s} ({s}); nothing was built.\n" ++
        "  The directory passed eb-local's checks, so it may be full or have changed since; df {s} shows its free space.", .{ job_root, storage.describeError(e), q(a, job_root) });
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

const WorkspaceRootRecord = struct {
    path: []const u8,
    dir_fd: ?sys.fd_t = null,
    name: []const u8 = "",
};

fn workspaceRegistryName(a: Allocator, root: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{x}", .{std.hash.Wyhash.hash(0, root)}) catch oom();
}

fn openWorkspaceRegistryDir(c: Ctx, prefix: []const u8, create: bool) PrivateChild {
    const state = std.fs.path.join(c.a, &.{ prefix, ".eb-local" }) catch oom();
    const state_fd = sys.openat(fsx.cwd, state, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
        error.NotFound => return .missing,
        else => return .{ .refused = str(c.a, "cannot open durable state directory {s} ({s})", .{ state, storage.describeError(e) }) },
    };
    defer sys.close(state_fd);
    const name = std.fmt.allocPrint(c.a, "workspace-roots-{d}", .{callerUid(c)}) catch oom();
    const path = std.fs.path.join(c.a, &.{ state, name }) catch oom();
    return switch (openPrivateChild(c, state_fd, name, path, create)) {
        .refused => |why| .{ .refused = str(c.a, "{s}; the workspace-root registry was not opened.", .{why}) },
        else => |got| got,
    };
}

fn workspaceRegistryDir(c: Ctx, prefix: []const u8, create: bool) ?sys.fd_t {
    return switch (openWorkspaceRegistryDir(c, prefix, create)) {
        .fd => |fd| fd,
        .missing => null,
        .refused => |why| die("{s}", .{why}),
    };
}

/// Set in main from EB_LOCAL_TEST_RECORD_OPEN_ERRNO, only in the test
/// artifact, so the temporary file of a workspace-root record is not
/// created and the open fails with that errno.
var test_record_open_errno: ?linux.E = null;

/// Write the registry entry for `root` and return null, or return why it
/// was not written, so the caller removes the workspace before it reports
/// that. Every failure, the registry and an entry that cannot be used
/// included, is returned. The entry is written to a temporary file in the
/// registry and renamed over the entry once the write, fsync and close
/// succeed. A failure before the rename removes only the temporary file,
/// so an entry that older workspaces under `root` were recorded in is
/// kept. A failed sync of the registry after the rename leaves the new
/// entry, which names the same root as any it replaced.
fn recordWorkspaceRoot(c: Ctx, prefix: []const u8, root: []const u8) ?[]const u8 {
    const dir = switch (openWorkspaceRegistryDir(c, prefix, true)) {
        .fd => |fd| fd,
        .missing => return str(c.a, "cannot create the workspace-root registry", .{}),
        .refused => |why| return why,
    };
    defer sys.close(dir);
    const name = workspaceRegistryName(c.a, root);
    if (fsx.statAt(dir, name, false)) |st| {
        if (!st.isReg() or st.uid != callerUid(c) or st.mode & 0o077 != 0)
            return str(c.a, "workstation workspace-root registry entry {s} must be a private regular file you own", .{name});
    } else |e| if (e != error.NotFound) return str(c.a, "cannot inspect workstation workspace-root registry ({s})", .{storage.describeError(e)});
    writeWorkspaceRecord(c.a, dir, name, root) catch |e|
        return str(c.a, "cannot record workstation workspace root {s} ({s})", .{ root, storage.describeError(e) });
    return null;
}

fn writeWorkspaceRecord(a: Allocator, dir: sys.fd_t, name: []const u8, root: []const u8) sys.Error!void {
    var rnd: [6]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &rnd, rnd.len, @as(u32, 0) });
    const tmp = std.fmt.allocPrint(a, ".{s}.{x}.tmp", .{ name, std.mem.readInt(u48, &rnd, .little) }) catch oom();
    if (comptime build_options.test_ops) if (test_record_open_errno) |e| {
        _ = try sys.result(@bitCast(-@as(isize, @backingInt(e))));
    };
    const fd = try sys.openat(dir, tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600);
    errdefer {
        const kept = sys.last_errno;
        sys.unlinkat(dir, tmp, 0) catch {};
        sys.last_errno = kept;
    }
    {
        errdefer sys.close(fd);
        try sys.writeAll(fd, root);
        try storage.fsyncWritten(fd);
    }
    try storage.closeWritten(fd);
    try sys.renameat(dir, tmp, dir, name);
    try storage.fsyncWritten(dir);
}

fn recordedWorkspaceRoots(c: Ctx, prefix: []const u8) []const WorkspaceRootRecord {
    const dir = workspaceRegistryDir(c, prefix, false) orelse return &.{};
    var out: std.ArrayList(WorkspaceRootRecord) = .empty;
    var it = fsx.DirIter.init(c.a, dir) catch {
        sys.close(dir);
        return &.{};
    };
    while (it.next() catch null) |entry| {
        // `recordWorkspaceRoot` names its temporary files with a leading dot.
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        const fd = sys.openat(dir, entry.name, .{ .NOFOLLOW = true, .CLOEXEC = true }, 0) catch continue;
        const st = fsx.fstat(fd) catch {
            sys.close(fd);
            continue;
        };
        if (!st.isReg() or st.uid != callerUid(c) or st.mode & 0o077 != 0) {
            sys.close(fd);
            continue;
        }
        const root = fsx.readAll(c.a, fd, sys.path_max) catch {
            sys.close(fd);
            continue;
        };
        sys.close(fd);
        if (!std.fs.path.isAbsolute(root)) continue;
        out.append(c.a, .{ .path = root, .dir_fd = dir, .name = c.a.dupe(u8, entry.name) catch oom() }) catch oom();
    }
    if (out.items.len == 0) sys.close(dir);
    return out.items;
}

fn rootHasOwnWorkspace(c: Ctx, root: []const u8) bool {
    const fd = fsx.openDir(fsx.cwd, root, false) catch return false;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return false;
    while (it.next() catch null) |entry| {
        const full = std.fs.path.join(c.a, &.{ root, entry.name }) catch oom();
        if (storage.ownWorkspace(root, full, callerUid(c))) return true;
    }
    return false;
}

fn forgetWorkspaceRootIfEmpty(c: Ctx, prefix: []const u8, root: []const u8) void {
    if (rootHasOwnWorkspace(c, root)) return;
    const dir = workspaceRegistryDir(c, prefix, false) orelse return;
    defer sys.close(dir);
    sys.unlinkat(dir, workspaceRegistryName(c.a, root), 0) catch {};
}

/// Write the one JSON document `clean --json` prints, and say whether it got out.
fn emitCleanJson(a: Allocator, prefix: []const u8, dry_run: bool, action: []const u8, targets: []const Target, spaces: []const []const u8, removed_items: usize, removed_workspaces: usize) bool {
    var items: std.ArrayList(CleanItemJson) = .empty;
    for (targets) |t| items.append(a, .{ .path = t.path, .kind = if (t.dir) "dir" else "file" }) catch oom();
    const line = jsonout.renderLine(a, CleanReport{
        .prefix = prefix,
        .dry_run = dry_run,
        .action = action,
        .items = items.items,
        .workspaces = spaces,
        .removed_items = removed_items,
        .removed_workspaces = removed_workspaces,
    }) catch oom();
    return emit(line);
}

/// What `clean` would remove: the files and directories under the prefix, and
/// the build workspaces of this job that no build holds.
const CleanPlan = struct {
    targets: []const Target,
    spaces: []const []const u8,
    /// Recorded workspace roots whose directory no longer exists.
    gone: []const WorkspaceRootRecord,

    /// Whether everything in `self` is still in `now`.
    fn holds(self: CleanPlan, now: CleanPlan) bool {
        for (self.targets) |t| {
            const found = for (now.targets) |u| {
                if (u.dir == t.dir and std.mem.eql(u8, u.path, t.path)) break true;
            } else false;
            if (!found) return false;
        }
        for (self.spaces) |w| {
            const found = for (now.spaces) |v| {
                if (std.mem.eql(u8, v, w)) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }
};

/// Recorded workspace roots that are gone are forgotten once the list is out.
fn forgetGoneRoots(plan: CleanPlan) void {
    for (plan.gone) |record| if (record.dir_fd) |dir| sys.unlinkat(dir, record.name, 0) catch {};
}

fn cleanPlan(c: Ctx, o: CleanOpts, d: Durable, roots: []const WorkspaceRootRecord, aged_before: i64) CleanPlan {
    const a = c.a;
    var collect: Collect = .{ .c = c };
    if (o.logs) collect.aged(d.logs, aged_before);
    if (o.sources) collect.files(d.sources);
    var spaces: std.ArrayList([]const u8) = .empty;
    var gone: std.ArrayList(WorkspaceRootRecord) = .empty;
    for (roots) |record| {
        const jr = record.path;
        const fd = fsx.openDir(fsx.cwd, jr, false) catch |e| switch (e) {
            error.NotFound => {
                gone.append(a, record) catch oom();
                continue;
            },
            else => die("cannot read {s} ({s})", .{ jr, storage.describeError(e) }),
        };
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
    return .{ .targets = collect.out.items, .spaces = spaces.items, .gone = gone.items };
}

fn cmdClean(c: Ctx, s: config.Settings, g: Global, o: CleanOpts, json: bool) u8 {
    const a = c.a;
    const p = place(c, s);
    const d = durableDirs(c, p.prefix, "nothing was removed");
    var roots: std.ArrayList(WorkspaceRootRecord) = .empty;
    if (o.workspaces) {
        roots.appendSlice(a, recordedWorkspaceRoots(c, p.prefix)) catch oom();
        if (nonEmpty(c.env.get("SLURM_JOB_ID")) != null and s.node_local_root.value.len > 0) {
            roots.append(a, .{ .path = checkedJobRoot(c, s, "nothing was removed") }) catch oom();
        } else if (localStorage(s, c, g) and roots.items.len == 0) {
            const local = checkedLocalRoot(c, s, "nothing was removed", false).path;
            if (fsx.statAt(fsx.cwd, local, false)) |st| {
                if (st.isDir()) roots.append(a, .{ .path = local }) catch oom();
            } else |_| {}
        } else if (roots.items.len == 0) {
            die("clean --workspaces found no recorded workstation roots and is not inside a Slurm job that made workspaces; nothing was removed.", .{});
        }
    }
    defer if (roots.items.len > 0 and roots.items[0].dir_fd != null) sys.close(roots.items[0].dir_fd.?);
    var trash = s.trash.value;
    const rtrash = proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null;
    switch (trash) {
        .auto => trash = if (rtrash != null) .rtrash else .none,
        .rtrash => if (rtrash == null) die("clean.trash is rtrash, but rtrash is not on PATH.", .{}),
        .none => {},
    }
    // find -mtime +N: more than N whole days old.
    const days: i64 = o.logs_days orelse s.logs_older_than_days.value;
    const aged_before: i64 = nowSecs() - (days + 1) * 86400 + 1;
    if (!o.dry_run and (o.logs or o.sources)) refuseIrregularPrefixLock(c, p.prefix);
    const plan = cleanPlan(c, o, d, roots.items, aged_before);
    const targets = plan.targets;
    const spaces = plan.spaces;
    if (targets.len == 0 and spaces.len == 0) {
        if (json) {
            if (!emitCleanJson(a, p.prefix, o.dry_run, "nothing", targets, spaces, 0, 0)) return unlisted("removed");
        } else {
            say("eb-local: nothing to clean in {s}", .{p.prefix});
            if (stdout.failed) return unlisted("removed");
        }
        if (!o.dry_run) for (roots.items) |record| if (record.dir_fd) |dir| {
            if (!rootHasOwnWorkspace(c, record.path)) sys.unlinkat(dir, record.name, 0) catch {};
        };
        return 0;
    }
    if (!json) {
        for (targets) |t| say("  {s}{s}", .{ t.path, if (t.dir) "/" else "" });
        for (spaces) |w| say("  {s}/ (build workspace)", .{w});
        if (stdout.failed) return unlisted("removed");
    }
    if (o.dry_run) {
        if (json) {
            _ = emitCleanJson(a, p.prefix, true, "dry-run", targets, spaces, 0, 0);
        } else {
            say("eb-local: dry run, nothing removed ({d} item(s), {d} workspace(s))", .{ targets.len, spaces.len });
        }
        return 0;
    }
    if (targets.len > 0 and trash != .rtrash and !o.delete) {
        notTrashed(s);
        if (json and !emitCleanJson(a, p.prefix, false, "refused", targets, spaces, 0, 0)) return unlisted("removed");
        forgetGoneRoots(plan);
        return 1;
    }
    // With `--json` the document is the list. It says what clean is about to
    // remove, so it is written, and has reached standard output, before the
    // first removal; a removal that then fails is a warning and exit status 1.
    if (json) {
        const planned = if (targets.len == 0) "workspaces-only" else if (trash == .rtrash) "trashed" else "deleted";
        if (!emitCleanJson(a, p.prefix, false, planned, targets, spaces, targets.len, spaces.len)) return unlisted("removed");
    }
    forgetGoneRoots(plan);
    // The list is out. Only now does clean hold the prefix lock, which makes
    // `.eb-local/.lock`, and check that the lock did not wait through a change
    // to what it listed.
    var prefix_lock: ?sys.fd_t = null;
    defer storage.releaseLockAfterError(&prefix_lock);
    if (o.logs or o.sources) {
        const eb_local_dir = std.fs.path.join(a, &.{ p.prefix, ".eb-local" }) catch oom();
        if (fsx.statAt(fsx.cwd, eb_local_dir, false)) |st| {
            if (st.isDir()) prefix_lock = acquirePrefixLock(c, p.prefix);
        } else |_| {}
    }
    if (!plan.holds(cleanPlan(c, o, d, roots.items, aged_before))) {
        warn("what clean listed changed while it waited for the prefix lock; nothing was removed. Run it again.", .{});
        return 1;
    }
    // Build workspaces are disposable scratch; they are deleted, not trashed.
    var removed_ws: usize = 0;
    for (spaces) |w| {
        if (storage.removeTree(a, w)) |_| {
            removed_ws += 1;
        } else |e| warn("cannot remove {s} ({s})", .{ w, storage.describeError(e) });
    }
    for (roots.items) |record| if (record.dir_fd) |dir| {
        if (!rootHasOwnWorkspace(c, record.path)) sys.unlinkat(dir, record.name, 0) catch {};
    };
    var removed_items: usize = 0;
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
                .unreaped => return 1,
            }
            removed_items = targets.len;
        } else {
            for (targets) |t| {
                if (t.dir) {
                    if (storage.removeTree(a, t.path)) |_| {
                        removed_items += 1;
                    } else |e| warn("cannot remove {s} ({s})", .{ t.path, storage.describeError(e) });
                } else {
                    if (sys.unlinkat(fsx.cwd, t.path, 0)) |_| {
                        removed_items += 1;
                    } else |e| warn("cannot remove {s} ({s})", .{ t.path, storage.describeError(e) });
                }
            }
        }
        for ([_][]const u8{ d.logs, d.sources }) |dir| {
            const st = fsx.statAt(fsx.cwd, dir, false) catch continue;
            removeEmptyDirs(c, dir, st.dev, 0);
        }
    }
    // Nothing is left to change, so no report below can stop a later step.
    if (!json) {
        if (spaces.len > 0) say("eb-local: removed {d} build workspace(s)", .{removed_ws});
        if (targets.len > 0 and trash == .rtrash) {
            say("eb-local: moved {d} item(s) to the trash (rtrash list, rtrash restore)", .{targets.len});
        } else if (targets.len > 0) {
            say("eb-local: deleted {d} item(s)", .{removed_items});
        }
    }
    const code: u8 = if (removed_ws < spaces.len or removed_items < targets.len) 1 else 0;
    return endLock(code, &prefix_lock, prefixLockPath(c, p.prefix));
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

/// What a shell without a module command sources for one.
const lmod_init = @embedFile("lmod-init.sh");
const dev_lang_dirs = @embedFile("dev-lang-dirs.sh");

/// A shell whose `module` is a host Lmod, such as a distribution's package
/// sets up in every login shell, sourced no init that puts EESSI's modules
/// on MODULEPATH. Where `$eb_local_stack` is not on MODULEPATH, EESSI's own
/// module directory goes first; a site's directory that holds it stays as is.
const eessi_modules =
    \\if ! module is-avail "$eb_local_stack" >/dev/null 2>&1 &&
    \\    [ -d "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/init/modules" ]; then
    \\    module use "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/init/modules" || :
    \\fi
    \\
;

/// The files an internal Bash build tries, in order. Doctor reports this list
/// for builds; env and dev select the evaluating shell through `lmod_init`.
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

/// Whether sourcing `file` in the shell a build starts leaves a `module`
/// command. Startup files are already out of `envp`, as they are out of
/// that shell.
fn initDefinesModule(c: Ctx, envp: proc.Envp, file: []const u8) bool {
    const a = c.a;
    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    const script = ". \"$1\" >/dev/null || :\ntype module >/dev/null 2>&1\n";
    const r = proc.run(a, bash, &.{ bash, "--noprofile", "--norc", "-c", script, "eb-local", file }, envp, .{
        .stdout_limit = 4096,
        .stderr_limit = 4096,
        .timeout_ms = 30_000,
    }) catch return false;
    return r.term.code() == 0;
}

const build_script_head = "set -eo pipefail\n" ++ (if (build_options.test_ops) test_prelude else "") ++
    \\trap 'trap - INT; kill -s INT "$$"' INT
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
    \\eb_local_stack=$stack
    \\
++ eessi_modules ++
    \\# EESSI-extend reads the variables when it loads, so it is loaded fresh.
    \\module unload "$extend" >/dev/null 2>&1 || true
    \\
;

const build_script_tail =
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
    \\# --variant: a copy of the named easyconfig with the variant's block
    \\# appended, so only that easyconfig is built with the variant's flags and
    \\# its module version ends in the variant's name.
    \\if [ -n "${EB_LOCAL_VARIANT:-}" ]; then
    \\    vdir="${saved[EASYBUILD_BUILDPATH]%/build}/variant"
    \\    mkdir -p "$vdir"
    \\    ec=$1
    \\    shift
    \\    if [[ $ec == */* ]]; then
    \\        base=$ec
    \\    else
    \\        base="$vdir/base.eb"
    \\        eb --copy-ec "$ec" "$base" >/dev/null || {
    \\            echo "eb-local: eb found no easyconfig $ec to make the $EB_LOCAL_VARIANT variant of; nothing was built" >&2
    \\            exit 1
    \\        }
    \\    fi
    \\    out="$vdir/${ec##*/}"
    \\    out="${out%.eb}-$EB_LOCAL_VARIANT.eb"
    \\    { cat "$base"; printf '\n%s\n' "$EB_LOCAL_VARIANT_BLOCK"; } > "$out"
    \\    echo "eb-local: building the $EB_LOCAL_VARIANT variant from $out; its module version ends in -$EB_LOCAL_VARIANT"
    \\    set -- "$out" "$@"
    \\fi
    \\unset EB_LOCAL_VARIANT EB_LOCAL_VARIANT_BLOCK
    \\# --cpu-target: EasyBuild runs the site's hooks and one more rule (the
    \\# GROMACS SIMD level follows the target). When the build presents another
    \\# CPU, every detector the build uses must name the target before eb starts.
    \\if [ -n "${EB_LOCAL_CPU_TARGET:-}" ]; then
    \\    export EB_LOCAL_BASE_HOOKS=${EASYBUILD_HOOKS-}
    \\    export EASYBUILD_HOOKS=$EB_LOCAL_HOOKS_FILE
    \\    case ${EB_LOCAL_MASK_ROUTE:-} in
    \\        cpuid | kvm | tcg)
    \\            pf_fd=no
    \\            [ -d /dev/fd ] && pf_fd=yes
    \\            pf_ad=$(env -u EESSI_SOFTWARE_SUBDIR_OVERRIDE bash "${EESSI_INIT_DIR_PATH:-${EESSI_PREFIX:-/nonexistent}/init}/eessi_archdetect.sh" cpupath 2>/dev/null) || pf_ad=
    \\            pf_sp=$(python3 -c 'import archspec.cpu as c; print(c.host())' 2>/dev/null) || pf_sp=
    \\            case $EB_LOCAL_CPU_TARGET in
    \\                aarch64/*) pf_flag=-mcpu pf_key=-mcpu= ;;
    \\                *) pf_flag=-march pf_key=-march= ;;
    \\            esac
    \\            pf_gcc=$(gcc "$pf_flag=native" -Q --help=target 2>/dev/null | awk -v k="$pf_key" '$1 == k { v = $2 } END { print v }') || pf_gcc=
    \\            pf_probe=$("${EB_LOCAL_PROBE:-/nonexistent}" 2>/dev/null) || pf_probe=
    \\            "$EB_LOCAL_SELF" __mask-preflight "$EB_LOCAL_CPU_TARGET" "$EB_LOCAL_MASK_ROUTE" "$pf_fd" "$pf_ad" "$pf_sp" "$pf_gcc" "$pf_probe" || exit 1
    \\            ;;
    \\    esac
    \\fi
    \\trap - INT
    \\exec eb "$@"
;

/// The easyconfig lines `--variant NAME` appends, or null for an unknown NAME.
/// Both keep a SYSTEM-toolchain easyconfig's options, which has none, and add
/// the variant's name to `versionsuffix`, so the module does not replace the
/// optimised one.
fn variantBlock(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "perf")) return variant_perf;
    if (std.mem.eql(u8, name, "debug")) return variant_debug;
    return null;
}

const variant_perf =
    \\# eb-local --variant perf: debug symbols and frame pointers for profilers.
    \\local_variant_flags = '-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer'
    \\if toolchain['name'].lower() != 'system':
    \\    toolchainopts = dict(locals().get('toolchainopts') or {})
    \\    toolchainopts['debug'] = True
    \\    for local_key in ('extra_cflags', 'extra_cxxflags', 'extra_fflags', 'extra_fcflags', 'extra_f90flags'):
    \\        toolchainopts[local_key] = ' '.join(x for x in (toolchainopts.get(local_key), local_variant_flags) if x)
    \\versionsuffix = (locals().get('versionsuffix') or '') + '-perf'
;

const variant_debug =
    \\# eb-local --variant debug: no optimisation and debug symbols, for debuggers and valgrind.
    \\if toolchain['name'].lower() != 'system':
    \\    toolchainopts = dict(locals().get('toolchainopts') or {})
    \\    toolchainopts['debug'] = True
    \\    toolchainopts['noopt'] = True
    \\versionsuffix = (locals().get('versionsuffix') or '') + '-debug'
;

/// `build_script_head`, the `unset` lines for `names`, then `build_script_tail`.
fn buildScript(a: Allocator, names: []const []const u8) []const u8 {
    return std.mem.concat(a, u8, &.{ build_script_head, installUnsetLines(a, names), build_script_tail }) catch oom();
}

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
    return if (configuredInstall(p).mode == .project) 0o002 else 0o077;
}

/// The command a build runs: `buildScript` in a clean bash, with the stack,
/// the extension, the install variable, the prefix and the mode as its first
/// five arguments, and eb's after them.
fn buildCommand(a: Allocator, c: Ctx, s: config.Settings, p: Place, args: []const []const u8) []const []const u8 {
    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    const install = configuredInstall(p);
    const build_script = buildScript(a, installNames(a, c));
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{
        bash,                 "--noprofile",         "--norc",           "-c",           build_script,           "eb-local",
        s.stack_module.value, s.extend_module.value, install.variable(), install.prefix, @tagName(install.mode),
    }) catch oom();
    argv.appendSlice(a, args) catch oom();
    return argv.items;
}

// ---- --cpu-target ---------------------------------------------------------

/// The route chosen for a `--cpu-target` build.
const MaskPlan = struct {
    subdir: []const u8,
    route: cpumask.Route,
    profile: ?cpumask.Profile,
};

/// Whether this binary has the `__vm-run` helper the kvm and tcg routes call.
fn vmHelperKnown() bool {
    return subcommand("__vm-run") != null;
}

/// Whether this binary has the `audit-isa` command the audit step calls.
fn auditKnown() bool {
    return subcommand("audit-isa") != null;
}

/// The EESSI subdirectory this host detects, from the archdetect script of
/// the EESSI version the build uses, or null when it cannot run.
fn hostSubdir(c: Ctx) ?[]const u8 {
    const repo = nonEmpty(c.env.get("EESSI_CVMFS_REPO")) orelse "/cvmfs/software.eessi.io";
    const ver = nonEmpty(c.env.get("EESSI_VERSION")) orelse "2026.06";
    const script = str(c.a, "{s}/versions/{s}/init/eessi_archdetect.sh", .{ repo, ver });
    if (!exists(script)) return null;
    const bash = (proc.which(c.a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse return null;
    const r = proc.run(c.a, bash, &.{ bash, "--noprofile", "--norc", script, "cpupath" }, c.envp, .{ .stdout_limit = 4096, .timeout_ms = 60_000 }) catch return null;
    if (r.term.code() != 0) return null;
    const out = std.mem.trim(u8, r.stdout, " \t\r\n");
    return c.a.dupe(u8, out[0 .. std.mem.indexOfScalar(u8, out, ':') orelse out.len]) catch oom();
}

/// The route for `--cpu-target`, or the reason there is none.
fn maskDecide(c: Ctx, g: Global, want_audit: bool) MaskPlan {
    const text = g.cpu_target.?;
    const subdir = switch (cpumask.resolveTarget(c.a, text)) {
        .subdir => |sd| sd,
        .refused => |m| die("--cpu-target {s}: {s}", .{ text, m }),
    };
    if (want_audit and !g.no_audit and !auditKnown())
        die("--cpu-target audits the installed tree with `eb-local audit-isa`, which this build of eb-local does not have; nothing was built. Give --no-audit to build without the audit.", .{});
    const profile = cpumask.findProfile(cpumask.builtinProfiles(c.a), subdir);
    const host = cpumask.readHost(c.a, hostSubdir(c), vmHelperKnown()) orelse die("--cpu-target works on x86_64 and aarch64 machines only", .{});
    return switch (cpumask.choose(c.a, g.mask, subdir, profile, host)) {
        .route => |r| .{ .subdir = subdir, .route = r, .profile = profile },
        .refuse => |m| die("--cpu-target {s}: {s}; nothing was built.", .{ subdir, m }),
    };
}

/// What a masked build adds to its command and environment.
const Masked = struct {
    vars: []const [2][]const u8,
    /// The words in front of the build command.
    prefix: []const []const u8,
};

/// Make the files `plan` needs in `dir` and the command words and variables
/// that apply them, or the reason they cannot be made.
fn maskMaterialize(c: Ctx, plan: MaskPlan, dir: []const u8) union(enum) { ok: Masked, failed: []const u8 } {
    const a = c.a;
    common.atomic.makedirs(dir) catch |e| return .{ .failed = str(a, "cannot create {s} ({s})", .{ dir, sys.describe(e) }) };
    var exe_buf: [sys.path_max]u8 = undefined;
    const self_exe = a.dupe(u8, selfExe(&exe_buf) orelse return .{ .failed = "cannot find this program's own path" }) catch oom();
    const hooks = str(a, "{s}/eb_local_hooks.py", .{dir});
    if (!cpumask.writeFile(a, hooks, cpumask.hooks_py, 0o644)) return .{ .failed = str(a, "cannot write {s}", .{hooks}) };
    var libs: cpumask.Libs = .{ .preload = "", .probe = "", .dir = "" };
    var rules_path: []const u8 = "";
    var prefix: []const []const u8 = &.{};
    if (plan.route == .kvm or plan.route == .tcg) {
        prefix = &.{ self_exe, "__vm-run", "--mode", @tagName(plan.route), "--cpu-target", plan.subdir, "--" };
    }
    if (plan.route == .cpuid) {
        const profile = plan.profile.?;
        const cache = rpath.cacheHome(a, c.env) catch return .{ .failed = "the cpuid route keeps its compiled library under $XDG_CACHE_HOME or $HOME/.cache, and neither is set" };
        var why: []const u8 = "";
        libs = cpumask.ensureLibs(a, c.envp, c.env.get("PATH") orelse "/usr/bin:/bin", cache, &why) orelse return .{ .failed = why };
        const host_text = cpumask.readFile(a, "/proc/cpuinfo", 4 << 20) orelse return .{ .failed = "cannot read /proc/cpuinfo" };
        const fake = str(a, "{s}/cpuinfo", .{dir});
        if (!cpumask.writeFile(a, fake, cpumask.maskedCpuinfo(a, profile, host_text), 0o644)) return .{ .failed = str(a, "cannot write {s}", .{fake}) };
        if (profile.arch == .x86_64) {
            rules_path = str(a, "{s}/rules", .{dir});
            if (!cpumask.writeFile(a, rules_path, cpumask.rulesFile(a, profile), 0o644)) return .{ .failed = str(a, "cannot write {s}", .{rules_path}) };
        }
        const path_env = c.env.get("PATH") orelse "/usr/bin:/bin";
        const unshare = (proc.which(a, "unshare", path_env) catch null) orelse return .{ .failed = "unshare is not on PATH; the cpuid route needs it for a user and mount namespace" };
        const setpriv = proc.which(a, "setpriv", path_env) catch null;
        prefix = cpumask.namespaceWords(a, unshare, setpriv, fake);
    }
    const vars = cpumask.maskVariables(a, plan.profile orelse .{ .subdir = plan.subdir, .arch = cpumask.archOf(plan.subdir) orelse .x86_64 }, libs, rules_path, hooks, self_exe, plan.route);
    return .{ .ok = .{ .vars = vars, .prefix = prefix } };
}

/// `__mask-preflight TARGET ROUTE DEVFD ARCHDETECT ARCHSPEC GCC PROBE`: what the
/// build script saw inside the mask, checked against the target. Prints one
/// line per check and exits 1 when any fails.
fn cmdMaskPreflight(c: Ctx, args: []const []const u8) u8 {
    if (args.len != 7) die("__mask-preflight takes TARGET ROUTE DEVFD ARCHDETECT ARCHSPEC GCC PROBE", .{});
    const a = c.a;
    const target = args[0];
    const route = std.meta.stringToEnum(cpumask.Route, args[1]) orelse die("__mask-preflight: unknown route {s}", .{args[1]});
    const profile = cpumask.findProfile(cpumask.builtinProfiles(a), target) orelse die("no mask profile for {s}", .{target});
    var obs: cpumask.Observed = .{ .devfd = std.mem.eql(u8, args[2], "yes") };
    if (args[3].len > 0) obs.archdetect = args[3];
    if (args[4].len > 0) obs.archspec = std.mem.trim(u8, args[4], " \t\r\n");
    if (args[5].len > 0) obs.gcc = std.mem.trim(u8, args[5], " \t\r\n");
    var it = std.mem.tokenizeAny(u8, args[6], " \t\r\n");
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        if (std.mem.eql(u8, tok[0..eq], "vendor")) obs.vendor = tok[eq + 1 ..];
        if (std.mem.eql(u8, tok[0..eq], "faulting")) obs.faulting = std.mem.eql(u8, tok[eq + 1 ..], "on");
    }
    const findings = cpumask.preflight(a, profile, route, obs);
    for (findings) |f| {
        if (f.ok) say("eb-local: preflight ok: {s}", .{f.text}) else say("eb-local: preflight FAILED: {s}", .{f.text});
    }
    if (cpumask.refused(findings)) {
        cli.err("eb-local: the build does not see {s}; nothing was built.\n", .{target});
        return 1;
    }
    return 0;
}

/// `__mask-run [--cpu-target T] [--mask M] -- COMMAND...`: run COMMAND the way
/// a `--cpu-target` build runs eb, with the same view of the CPU and no build.
fn cmdMaskRun(c: Ctx, g: Global, args: []const []const u8) u8 {
    if (g.cpu_target == null) die("__mask-run needs --cpu-target", .{});
    if (args.len == 0) die("__mask-run needs a command after --", .{});
    const a = c.a;
    const plan = maskDecide(c, g, false);
    const tmp = nonEmpty(c.env.get("TMPDIR")) orelse "/tmp";
    const dir = fsx.mkdtemp(a, tmp, "eb-local-mask-") catch |e| die("cannot make a directory in {s} ({s})", .{ tmp, @errorName(e) });
    defer fsx.deleteTree(a, fsx.cwd, dir) catch {};
    const masked = switch (maskMaterialize(c, plan, dir)) {
        .ok => |m| m,
        .failed => |why| die("{s}", .{why}),
    };
    var env = c.env.clone(a) catch oom();
    for (masked.vars) |kv| env.put(kv[0], kv[1]) catch oom();
    const argv = std.mem.concat(a, []const u8, &.{ masked.prefix, args }) catch oom();
    const exe = if (argv[0].len > 0 and argv[0][0] == '/') argv[0] else (proc.which(a, argv[0], c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse die("{s}: not found", .{argv[0]});
    const full = a.dupe([]const u8, argv) catch oom();
    full[0] = exe;
    return switch (runAttached(a, full, envpOf(a, &env))) {
        .exit => |code| code,
        .signal, .unreaped => 1,
    };
}

/// `doctor --cpu-target TARGET`: whether this machine can present TARGET, and
/// by which route.
fn reportCpuTarget(c: Ctx, text: []const u8, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) void {
    const a = c.a;
    const path_env = c.env.get("PATH") orelse "";
    const host = cpumask.readHost(a, hostSubdir(c), vmHelperKnown()) orelse {
        note(a, out, json_lines, "warn", "--cpu-target works on x86_64 and aarch64 machines only", .{});
        return;
    };
    note(a, out, json_lines, "info", "host: {s}, {s}, kernel {s}", .{ @tagName(host.arch), cpumask.hostModel(a), cpumask.kernelRelease(a) });
    if (host.subdir) |h| note(a, out, json_lines, "info", "EESSI detects this host as {s}", .{h}) else note(a, out, json_lines, "info", "the EESSI archdetect script was not found; the host's own target is not known", .{});
    if (host.arch == .x86_64) {
        if (host.faulting) {
            note(a, out, json_lines, "ok  ", "CPUID faulting is available: the cpuid route can present another x86_64 CPU", .{});
        } else note(a, out, json_lines, "info", "CPUID faulting is not available (AMD CPUs need Linux 6.17 or later); the cpuid route is out", .{});
    } else note(a, out, json_lines, "info", "aarch64 has no CPUID trap; the cpuid route masks getauxval and /proc/cpuinfo", .{});
    if (host.kvm) {
        note(a, out, json_lines, "ok  ", "/dev/kvm is usable: the kvm route can run a CPU model of this architecture", .{});
    } else note(a, out, json_lines, "info", "/dev/kvm is not usable by this user; the kvm route is out", .{});
    for ([_][]const u8{ "qemu-system-x86_64", "qemu-system-aarch64" }) |name| {
        if (proc.which(a, name, path_env) catch null) |exe| {
            note(a, out, json_lines, "ok  ", "{s}: {s}", .{ name, exe });
        } else note(a, out, json_lines, "info", "{s} is not on PATH; the tcg route for that architecture is out", .{name});
    }
    for ([_][]const u8{ "cc", "unshare", "mount" }) |name| {
        if (proc.which(a, name, path_env) catch null) |exe| {
            note(a, out, json_lines, "ok  ", "{s}: {s}", .{ name, exe });
        } else note(a, out, json_lines, "warn", "{s} is not on PATH; the cpuid route needs it", .{name});
    }
    if (vmHelperKnown()) note(a, out, json_lines, "ok  ", "this eb-local has the virtual machine routes (__vm-run)", .{}) else note(a, out, json_lines, "info", "this eb-local has no __vm-run helper: the kvm and tcg routes refuse", .{});
    if (auditKnown()) note(a, out, json_lines, "ok  ", "this eb-local has audit-isa", .{}) else note(a, out, json_lines, "info", "this eb-local has no audit-isa: a --cpu-target build needs --no-audit", .{});
    const subdir = switch (cpumask.resolveTarget(a, text)) {
        .subdir => |sd| sd,
        .refused => |m| {
            note(a, out, json_lines, "warn", "{s}", .{m});
            return;
        },
    };
    const profile = cpumask.findProfile(cpumask.builtinProfiles(a), subdir);
    if (profile != null) {
        note(a, out, json_lines, "ok  ", "a mask profile exists for {s}", .{subdir});
    } else note(a, out, json_lines, "info", "no mask profile exists for {s}; only the virtual machine routes can present it", .{subdir});
    switch (cpumask.choose(a, .auto, subdir, profile, host)) {
        .route => |r| note(a, out, json_lines, "ok  ", "--mask auto builds {s} by the {s} route", .{ subdir, @tagName(r) }),
        .refuse => |m| note(a, out, json_lines, "warn", "{s} cannot be built here: {s}", .{ subdir, m }),
    }
}

/// The software directories (NAME/VERSION) below the tree for `subdir` that
/// this build made, by the time their directories were created.
fn installedSince(c: Ctx, prefix: []const u8, subdir: []const u8, started: i64) []const []const u8 {
    const a = c.a;
    var trees: std.ArrayList([]const u8) = .empty;
    findTrees(c, std.fs.path.join(a, &.{ prefix, "versions" }) catch oom(), &trees, 0);
    var out: std.ArrayList([]const u8) = .empty;
    for (trees.items) |tree| {
        if (!std.mem.eql(u8, treeTarget(tree), subdir)) continue;
        const software = std.fs.path.join(a, &.{ tree, "software" }) catch oom();
        const sfd = fsx.openDir(fsx.cwd, software, false) catch continue;
        defer sys.close(sfd);
        var names = fsx.DirIter.init(a, sfd) catch continue;
        while (names.next() catch null) |n| {
            if (n.name.len == 0 or n.name[0] == '.' or !isDirAt(sfd, n.name)) continue;
            const name_path = std.fs.path.join(a, &.{ software, a.dupe(u8, n.name) catch oom() }) catch oom();
            const nfd = fsx.openDir(fsx.cwd, name_path, false) catch continue;
            defer sys.close(nfd);
            var vers = fsx.DirIter.init(a, nfd) catch continue;
            while (vers.next() catch null) |v| {
                if (v.name.len == 0 or v.name[0] == '.' or !isDirAt(nfd, v.name)) continue;
                const vp = std.fs.path.join(a, &.{ name_path, a.dupe(u8, v.name) catch oom() }) catch oom();
                const st = fsx.statAt(fsx.cwd, vp, false) catch continue;
                if (st.ctime.sec >= started - 1) out.append(a, vp) catch oom();
            }
        }
    }
    return out.items;
}

fn setMode(path: []const u8, mode: u32) void {
    var zb: [sys.path_max:0]u8 = undefined;
    const z = sys.z(&zb, path) catch return;
    _ = linux.fchmodat(linux.AT.FDCWD, z.ptr, @as(linux.mode_t, @intCast(mode)));
}

/// After a successful `--cpu-target` build: audit what it installed for
/// instructions the target lacks, and write the provenance record into each
/// installed directory. Returns false when the audit fails.
fn maskAfterBuild(c: Ctx, g: Global, plan: MaskPlan, prefix: []const u8, started: i64) bool {
    const a = c.a;
    const installed = installedSince(c, prefix, plan.subdir, started);
    var exe_buf: [sys.path_max]u8 = undefined;
    const self_exe = selfExe(&exe_buf) orelse "";
    var failed = false;
    const model = cpumask.hostModel(a);
    const kernel = cpumask.kernelRelease(a);
    if (installed.len == 0) warn("--cpu-target {s}: the build installed nothing new below {s}, so there is nothing to audit or record", .{ plan.subdir, prefix });
    for (installed) |dir| {
        var audit: []const u8 = "skipped";
        if (!g.no_audit) {
            say("eb-local: auditing {s} for instructions {s} lacks", .{ dir, plan.subdir });
            const rc = switch (runAttached(a, &.{ self_exe, "audit-isa", dir, "--target", plan.subdir }, c.envp)) {
                .exit => |code| code,
                .signal, .unreaped => 1,
            };
            audit = if (rc == 0) "pass" else "fail";
            if (rc != 0) {
                failed = true;
                cli.err("eb-local: the ISA audit of {s} for {s} failed\n", .{ dir, plan.subdir });
            }
        }
        const eb_dir = std.fs.path.join(a, &.{ dir, "easybuild" }) catch oom();
        if (!isDir(eb_dir)) continue;
        const text = cpumask.provenanceJson(a, .{
            .target = plan.subdir,
            .route = plan.route,
            .profile = if (plan.profile) |pr| pr.subdir else "",
            .host_cpu = model,
            .kernel = kernel,
            .version = version,
            .audit = audit,
        });
        // EasyBuild leaves an installation read-only; the record goes in and the mode goes back.
        const old_mode: ?u32 = if (fsx.statAt(fsx.cwd, eb_dir, false)) |st| st.perm() else |_| null;
        if (old_mode) |m| setMode(eb_dir, m | 0o200);
        if (!cpumask.writeProvenance(a, eb_dir, text)) warn("cannot write the build-mode record in {s}", .{eb_dir});
        if (old_mode) |m| setMode(eb_dir, m);
    }
    return !failed;
}

/// What a build runs: its script, after the variables eb-local sets for it
/// and a `set --` line with its arguments, and the checks eb-local makes
/// first as comments. Nothing is created and nothing runs, so it also works
/// outside an allocation. $W stands for the workspace a build makes in the
/// selected local workspace root.
fn explainBuild(c: Ctx, s: config.Settings, g: Global, args: []const []const u8, mask_plan: ?MaskPlan) u8 {
    const a = c.a;
    const p = place(c, s);
    const install = configuredInstall(p);
    const build_script = buildScript(a, installNames(a, c));
    const d = durableDirs(c, p.prefix, "a build would stop here");
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "# eb-local --explain: the script a build runs, with its environment and arguments. Nothing was created or run.\n") catch oom();
    out.print(a, "# Installs as a {s} install into {s} (prefix from {s}).\n", .{
        @tagName(install.mode), install.prefix, if (install.mode == .project) s.project.from else s.prefix.from,
    }) catch oom();
    if (localStorage(s, c, g)) {
        out.appendSlice(a, "# Checks first: a private workspace on this workstation's local disk,\n") catch oom();
    } else if (nonEmpty(c.env.get("SLURM_JOB_ID"))) |job| {
        out.print(a, "# Checks first: Slurm job {s}, its own node-local {s} mount under {s},\n", .{ job, s.node_local_fstype.value, s.node_local_root.value }) catch oom();
    } else {
        out.appendSlice(a, "# Checks first: a Slurm job (there is none here, so a build would stop now),\n") catch oom();
        if (s.allocation_hint.value.len > 0) out.print(a, "#   for example: {s}\n", .{s.allocation_hint.value}) catch oom();
        if (s.node_local_root.value.len > 0)
            out.print(a, "#   then its own node-local {s} mount under {s},\n", .{ s.node_local_fstype.value, s.node_local_root.value }) catch oom();
    }
    out.appendSlice(a, "#   and a prefix, sources and logs that are not on shared or node-local scratch.\n") catch oom();
    const jobs = batchLines(c, s, g, p, args);
    if (jobs.len > 0) {
        out.appendSlice(a, "# On each node type the site file lists in [build.node_types], the same build as a batch job:\n") catch oom();
        for (jobs) |line| out.print(a, "#   {s}\n", .{line}) catch oom();
    }
    out.appendSlice(a, "# W is a new private workspace eb-local makes there; it is removed after a good build.\n") catch oom();
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
        out.appendSlice(a, ",\n# and, because build.clear_foreign_prefixes is set, without entries of PERL5LIB, PYTHONPATH, R_LIBS*, JULIA_LOAD_PATH, JULIA_DEPOT_PATH, NODE_PATH, CMAKE_PREFIX_PATH and PKG_CONFIG_PATH outside the approved prefixes, and without a compiler-wrapper, Cargo linker or Makevars variable that resolves outside them") catch oom();
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
    if (g.variant) |v| {
        out.print(a, "export EB_LOCAL_VARIANT={s}\n", .{q(a, v)}) catch oom();
        out.print(a, "export EB_LOCAL_VARIANT_BLOCK={s}\n", .{q(a, variantBlock(v).?)}) catch oom();
    }
    if (mask_plan) |m| {
        out.print(a, "# --cpu-target {s}: the {s} route", .{ m.subdir, @tagName(m.route) }) catch oom();
        switch (m.route) {
            .native => out.appendSlice(a, "; this host already is the target, so nothing is masked.\n") catch oom(),
            .cpuid => out.appendSlice(a, ".\n# The build runs in a user and mount namespace that keeps your uid, with a /proc/cpuinfo\n# of the target bound over the real one, and a preload library (compiled with this host's cc\n# on first use) that answers every CPUID as the target. Before eb starts, EESSI archdetect,\n# archspec, gcc -march=native and the CPUID vendor must all name the target.\n") catch oom(),
            .kvm, .tcg => out.print(a, ".\n# The build runs in a virtual machine: eb-local __vm-run --mode {s} --cpu-target {s} -- COMMAND...\n", .{ @tagName(m.route), m.subdir }) catch oom(),
        }
        out.print(a, "export EESSI_SOFTWARE_SUBDIR_OVERRIDE={s}\n", .{q(a, m.subdir)}) catch oom();
        out.print(a, "export EB_LOCAL_CPU_TARGET={s}\n", .{q(a, m.subdir)}) catch oom();
        if (!g.no_audit) out.print(a, "# After a successful build: eb-local audit-isa DIR --target {s}, for each installed directory.\n", .{m.subdir}) catch oom();
        out.appendSlice(a, "# Each installed directory gets easybuild/eb-local-build-mode.json: route, profile, host CPU, kernel, eb-local version, audit result.\n") catch oom();
    }
    out.print(a, "umask {o:0>3}\n", .{buildUmask(p)}) catch oom();
    const argv = buildCommand(a, c, s, p, args);
    out.appendSlice(a, "# It runs in a clean bash (no profile, no rc file):\n#  ") catch oom();
    for (argv[0..4]) |x| out.print(a, " {s}", .{x}) catch oom();
    out.appendSlice(a, " \"$SCRIPT\"") catch oom();
    for (argv[5..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.appendSlice(a, "\n# where SCRIPT is everything after the next line.\nset --") catch oom();
    for (argv[6..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.print(a, "\n{s}\n", .{build_script}) catch oom();
    return if (emit(out.items)) 0 else 1;
}

/// A test capacity, `BYTES:INODES`, or `BYTES:INODES:uncounted` for a file
/// system that reports no inode table.
fn capacityOverride(value: []const u8) ?storage.Capacity {
    const suffix = ":uncounted";
    const counted = !std.mem.endsWith(u8, value, suffix);
    const pair = if (counted) value else value[0 .. value.len - suffix.len];
    const split = std.mem.indexOfScalar(u8, pair, ':') orelse return null;
    return .{
        .bytes = std.fmt.parseInt(u64, pair[0..split], 10) catch return null,
        .inodes = std.fmt.parseInt(u64, pair[split + 1 ..], 10) catch return null,
        .inodes_counted = counted,
    };
}

fn prefixCapacityOverride(c: Ctx) ?storage.Capacity {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_PREFIX_CAPACITY"))) |value| return capacityOverride(value);
    }
    return null;
}

fn prefixCapacity(c: Ctx, path: []const u8) ?storage.Capacity {
    return prefixCapacityOverride(c) orelse (storage.capacity(path) catch null);
}

/// The durable directories of a build, refused when a link leads them, or
/// the trees below the prefix, onto storage that does not outlive the job.
/// It makes nothing, so it runs before the prefix exists as well as after.
fn buildTrees(c: Ctx, refused: []const RefusedTree, prefix: []const u8) Durable {
    const d = durableDirs(c, prefix, "nothing was built");
    // The trees a build writes below the prefix must not lead onto refused
    // storage either, through a symbolic link made later.
    for ([_][]const u8{ "versions", ".eb-local" }) |sub| {
        const path = std.fs.path.join(c.a, &.{ prefix, sub }) catch oom();
        const resolved = storage.canonical(c.a, path, c.cwd) catch oom();
        for (refused) |t| if (storage.under(resolved, t.path))
            die("{s} leads to {s}, under {s}, {s}; nothing was built.\n  " ++ outlive ++ ": replace the symbolic link in {s} with a directory, or " ++ prefix_fix ++ ".", .{ path, resolved, t.path, t.what, path });
    }
    return d;
}

fn cmdBuild(c: Ctx, s: config.Settings, g: Global, args: []const []const u8) u8 {
    const a = c.a;
    if (args.len == 0) {
        cli.err("{s}", .{usage_text});
        return 2;
    }
    if (g.variant != null and !std.mem.endsWith(u8, args[0], ".eb"))
        die("--variant needs the easyconfig as the first argument; got '{s}'", .{args[0]});
    const mask_plan: ?MaskPlan = if (g.cpu_target != null) maskDecide(c, g, true) else null;
    if (g.explain) return explainBuild(c, s, g, args, mask_plan);
    if (!localStorage(s, c, g) and nonEmpty(c.env.get("SLURM_JOB_ID")) == null) {
        warn("not inside a Slurm job: SLURM_JOB_ID is unset or empty; nothing was built.", .{});
        if (s.node_local_root.value.len == 0) {
            cli.err("  Slurm is present, but no site file sets storage.node_local_root, the directory\n", .{});
            cli.err("  that holds each job's node-local mount. Install the site file, or explicitly\n", .{});
            var command: std.ArrayList([]const u8) = .empty;
            command.append(a, "eb-local") catch oom();
            appendConfigurationOptions(c, s, g, locate(c, s), &command);
            command.append(a, "--workstation") catch oom();
            for (args) |arg| command.append(a, qSingleLine(a, arg)) catch oom();
            cli.err("  opt in to this machine's local disk with: {s}", .{std.mem.join(a, " ", command.items) catch oom()});
            cli.err("\n", .{});
            return 2;
        }
        cli.err("  Software is built for the CPU of the node that runs eb-local, so build\n", .{});
        cli.err("  inside an allocation on the node type that will run it{s}\n", .{if (s.allocation_hint.value.len > 0) ", for example:" else ""});
        if (s.allocation_hint.value.len > 0) cli.err("  {s}\n", .{s.allocation_hint.value});
        const jobs = batchLines(c, s, g, place(c, s), args);
        if (jobs.len > 0) cli.err("  or as a batch job, on each node type the site file lists:\n", .{});
        for (jobs) |line| cli.err("  {s}\n", .{line});
        return 2;
    }
    const job_root = checkedWorkspaceRoot(c, s, g, "nothing was built");
    var p = place(c, s);
    // The process umask EESSI-extend gives the install, as `eb-local eb`
    // sets it: 002 for a project, so that every member can write the
    // directories builds share, and 077 for a user. What eb-local makes
    // there takes it too.
    _ = linux.syscall1(.umask, buildUmask(p));
    const refused = refusedTrees(c, s, true);
    for (refused) |t| if (storage.under(p.prefix, t.path))
        die("the install prefix {s} [{s}] is under {s}, {s}; nothing was built.\n  " ++ outlive ++ "; " ++ prefix_fix ++ ".", .{ p.prefix, prefixFrom(s, p), t.path, t.what });
    {
        // Said before the prefix exists, so a standard output that cannot take
        // it leaves nothing behind; the canonical form is what realpath gives
        // once the prefix is made.
        const shown_prefix = storage.canonical(a, p.prefix, c.cwd) catch oom();
        _ = buildTrees(c, refused, shown_prefix);
        var shown: std.ArrayList(u8) = .empty;
        shown.appendSlice(a, replay(a, "--explain", s, g, shown_prefix, &.{})) catch oom();
        for (args) |x| shown.print(a, " {s}", .{q(a, x)}) catch oom();
        say("eb-local: what this runs: eb-local {s}", .{shown.items});
        if (stdout.failed) return unlisted("built");
    }
    common.atomic.makedirs(p.prefix) catch |e| die("installation prefix {s} is not writable ({s})", .{ p.prefix, storage.describeError(e) });
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = sys.z(&zb, p.prefix) catch |e| die("installation prefix {s} is not writable ({s})", .{ p.prefix, storage.describeError(e) });
        const acc_err = linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0));
        if (comptime build_options.test_ops) {
            if (storage.test_prefix_errno) |e|
                die("installation prefix {s} is not writable ({s})", .{ p.prefix, sys.describeErrno(e) });
        }
        if (acc_err != .SUCCESS)
            die("installation prefix {s} is not writable ({s})", .{ p.prefix, sys.describeErrno(acc_err) });
        var buf: [sys.path_max]u8 = undefined;
        p.prefix = a.dupe(u8, fsx.realpath(fsx.cwd, p.prefix, &buf) catch |e| die("cannot resolve installation prefix {s} ({s})", .{ p.prefix, storage.describeError(e) })) catch oom();
    }
    if (prefixCapacity(c, p.prefix)) |cap| {
        if (cap.exhausted())
            die("installation prefix {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ p.prefix, cap.bytes, cap.inodes });
    }
    const d = buildTrees(c, refused, p.prefix);

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
    const ws_held = storage.makeLockedWorkspace(a, job_root, &.{ "build", "tmp", "cache", "cargo", "source-index" }) catch |e| workspaceFailed(a, job_root, e);
    const work = ws_held.path;
    var ws_lock: ?sys.fd_t = ws_held.lock;
    defer storage.releaseLockAfterError(&ws_lock);
    const ws_lock_path = std.fs.path.join(a, &.{ work, ".eb-local.lock" }) catch oom();
    if (comptime build_options.test_ops) {
        if (storage.test_workspace_errno) |e| {
            if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
            die("cannot create {s} ({s})", .{ d.sources, storage.describeError(storage.injectedSysError(e)) });
        }
    }
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
        if (comptime build_options.test_ops) {
            if (storage.test_logs_errno) |e| {
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                die("logs directory {s} is not writable ({s})", .{ d.logs, sys.describeErrno(e) });
            }
        }
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
        const lock_cancel = blk_lc: {
            var block = linux.sigemptyset();
            for (passed_on) |sig| linux.sigaddset(&block, sig);
            var prev_mask: linux.sigset_t = undefined;
            _ = linux.sigprocmask(linux.SIG.BLOCK, &block, &prev_mask);
            if (guard.received()) |sig| {
                _ = linux.sigprocmask(linux.SIG.SETMASK, &prev_mask, null);
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                guard.release();
                return stop(.{ .signal = sig });
            }
            const lc = storage.LockCancel.hold();
            _ = linux.sigprocmask(linux.SIG.SETMASK, &prev_mask, null);
            break :blk_lc lc;
        };
        const acquired = storage.acquireBoundedLockCancel(a, lock_path, timeout_ms, true, lock_cancel.flag(), &lock_err);
        var post_block = linux.sigemptyset();
        for (passed_on) |sig| linux.sigaddset(&post_block, sig);
        var post_mask: linux.sigset_t = undefined;
        _ = linux.sigprocmask(linux.SIG.BLOCK, &post_block, &post_mask);
        const canceled_sig = lock_cancel.received();
        lock_cancel.release();
        if (canceled_sig) |sig| _ = first_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
        _ = linux.sigprocmask(linux.SIG.SETMASK, &post_mask, null);
        break :blk switch (acquired) {
            .held => |fd| fd,
            .unlocked => null,
            .canceled => {
                const sig = canceled_sig orelse guard.received() orelse .TERM;
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                guard.release();
                return stop(.{ .signal = sig });
            },
            .failed => {
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                die("{s}", .{lock_err});
            },
        };
    };
    defer storage.releaseLockAfterError(&prefix_lock);
    if (localStorage(s, c, g)) if (recordWorkspaceRoot(c, p.prefix, job_root)) |why| {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
        die("{s}", .{why});
    };
    var env = c.env.clone(a) catch oom();
    for (install_vars) |v| _ = env.swapRemove(v);
    _ = env.swapRemove("EB_LOCAL_SITE_TOOLCHAINS");
    _ = env.swapRemove("EB_LOCAL_VARIANT");
    _ = env.swapRemove("EB_LOCAL_VARIANT_BLOCK");
    for ([_][]const u8{ "EB_LOCAL_CPU_TARGET", "EB_LOCAL_MASK_ROUTE", "EB_LOCAL_PROBE", "EB_LOCAL_SELF", "EB_LOCAL_HOOKS_FILE", "EB_LOCAL_BASE_HOOKS" }) |name| _ = env.swapRemove(name);
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
    if (g.variant) |v| {
        env.put("EB_LOCAL_VARIANT", v) catch oom();
        env.put("EB_LOCAL_VARIANT_BLOCK", variantBlock(v).?) catch oom();
    }
    for (buildVariables(a, work, d)) |kv| env.put(kv[0], kv[1]) catch oom();
    for (s.eessi.items) |v| env.put(v.name, v.value) catch oom();
    for (values) |v| env.put(v.name, v.value) catch oom();
    var wrap: []const []const u8 = &.{};
    if (mask_plan) |m| {
        switch (maskMaterialize(c, m, std.fs.path.join(a, &.{ work, "mask" }) catch oom())) {
            .ok => |masked| {
                for (masked.vars) |kv| env.put(kv[0], kv[1]) catch oom();
                wrap = masked.prefix;
            },
            .failed => |why| {
                if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
                die("--cpu-target {s}: {s}; nothing was built.", .{ m.subdir, why });
            },
        }
        say("eb-local: --cpu-target {s}, {s} route{s}", .{ m.subdir, @tagName(m.route), if (m.route == .cpuid) " (CPUID faulting, namespaced /proc/cpuinfo)" else "" });
    }

    if (guard.received()) |sig| {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch {};
        guard.release();
        return stop(.{ .signal = sig });
    }
    // The guard stays until the logs are clean: a signal stops the build, but
    // eb-local first waits for EasyBuild, which writes them, to exit. Logs
    // are cleaned only after the process group is reaped. A SIGKILL timeout
    // leaves them in place.
    const build_argv = std.mem.concat(a, []const u8, &.{ wrap, buildCommand(a, c, s, p, args) }) catch oom();
    const ran = guard.run(a, build_argv, envpOf(a, &env)) catch die("cannot start {s}", .{build_argv[0]});
    var rc: u8 = if (guard.received() != null) 1 else switch (ran) {
        .exit => |code| code,
        .signal => 1,
        .unreaped => 1,
    };
    var audit_failed = false;
    if (mask_plan) |m| if (rc == 0) {
        if (!maskAfterBuild(c, g, m, p.prefix, started)) {
            audit_failed = true;
            rc = 1;
        }
    };

    // Redaction requires ECHILD. A descendant still alive after the SIGKILL
    // deadline can write a secret into a log that was just cleaned, so a
    // timed-out reap leaves the logs alone and the build exits 1.
    if (ran == .unreaped) {
        if (values.len > 0)
            warn("build logs were not cleaned of secrets, because a descendant may still write them", .{});
    } else if (values.len > 0) {
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
    // The workspace goes only once what was said about the logs has reached
    // standard output; until then it stays, as after a failed build. Its
    // lock is released after the last line, so a failed write is reported
    // and a failed release after it is not.
    const remove = rc == 0 and !keep and !stdout.failed;
    if (!remove) {
        if (localStorage(s, c, g))
            warn("build workspace kept at {s};", .{work})
        else
            warn("build workspace kept at {s}; it goes when the allocation ends,", .{work});
        cli.err("  or now with: eb-local clean --workspaces --no-logs\n", .{});
    }
    if (rc == 0) {
        say("", .{});
        say("eb-local: done. To use the modules in a new shell or job:", .{});
        say("  eval \"$(eb-local {s})\"", .{replay(a, "env", s, g, p.prefix, &.{})});
    }
    var released: u8 = 0;
    if (remove) {
        const mask = blockPassedOn();
        released = endLock(if (guard.received() != null) 1 else 0, &ws_lock, ws_lock_path);
        restoreMask(&mask);
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch |e| {
            if (localStorage(s, c, g))
                warn("cannot remove {s} ({s}); run eb-local clean --workspaces", .{ work, @errorName(e) })
            else
                warn("cannot remove {s} ({s}); it goes when the allocation ends", .{ work, @errorName(e) });
        };
        if (localStorage(s, c, g)) forgetWorkspaceRootIfEmpty(c, p.prefix, job_root);
    }
    const mask = blockPassedOn();
    const ended: Run = if (guard.received()) |sig| .{ .signal = sig } else ran;
    const code: u8 = switch (ended) {
        .exit => |x| if (x != 0) x else if (audit_failed) 1 else released,
        .signal => 1,
        .unreaped => 1,
    };
    const final = endLock(endLock(code, &ws_lock, ws_lock_path), &prefix_lock, prefixLockPath(c, p.prefix));
    restoreMask(&mask);
    const late: Run = if (guard.received()) |sig| .{ .signal = sig } else ended;
    guard.release();
    return if (late == .signal) stop(late) else final;
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

fn validListFilter(filter: []const u8) bool {
    if (std.mem.endsWith(u8, filter, "/"))
        return filter.len > 1 and config.validModule(filter[0 .. filter.len - 1]);
    return config.validModule(filter);
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
        return if (emit(out.items)) 0 else 1;
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
        return if (emit(out.items)) 0 else 1;
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
    return if (emit(out.items)) 0 else 1;
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
        .none => note(a, out, json_lines, "info", "no PERL5LIB, PYTHONPATH, R_LIBS*, JULIA_LOAD_PATH, JULIA_DEPOT_PATH, NODE_PATH, CMAKE_PREFIX_PATH or PKG_CONFIG_PATH entry, and no compiler-wrapper, Cargo linker or Makevars variable, points outside the approved prefixes", .{}),
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
    /// `--profiling`: report what perf, valgrind and debuggers may do here.
    profiling: bool = false,
    /// `--cpu-target TARGET`: report whether this machine can present TARGET.
    cpu_target: ?[]const u8 = null,
    /// `--workspace`: exercise and describe this existing build workspace.
    workspace: ?[]const u8 = null,
};

fn workspaceCapacityOverride(c: Ctx) ?storage.Capacity {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_WORKSPACE_CAPACITY"))) |value| return capacityOverride(value);
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
        note(a, out, json_lines, "FAIL", "workspace {s} cannot be read ({s})", .{ path, storage.describeError(err) });
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
        note(a, out, json_lines, "FAIL", "workspace {s} probe could not complete ({s})", .{ path, storage.describeError(err) });
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
    // The workspace path is canonical. A shared root is whatever the site
    // file wrote, so a link or a dot component has to be resolved before the
    // comparison or the workspace looks node-local.
    var shared: std.ArrayList([]const u8) = .empty;
    for (s.shared_scratch.value) |root| shared.append(a, storage.canonical(a, root, c.cwd) catch oom()) catch oom();
    const class = storage.workspaceClass(path, mount.fstype, shared.items);
    note(a, out, json_lines, "info", "workspace {s}: {s} file system, classified {s}", .{ path, mount.fstype, class });
    const available: ?storage.Capacity = workspaceCapacityOverride(c) orelse storage.capacity(path) catch |err| blk: {
        note(a, out, json_lines, "FAIL", "workspace {s}: free bytes and inodes cannot be read ({s})", .{ path, storage.describeError(err) });
        failed = true;
        break :blk null;
    };
    if (available) |free| {
        if (free.exhausted()) {
            note(a, out, json_lines, "FAIL", "workspace {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ path, free.bytes, free.inodes });
            failed = true;
        } else if (free.inodes_counted) {
            note(a, out, json_lines, "info", "workspace {s}: {d} free bytes, {d} free inodes", .{ path, free.bytes, free.inodes });
        } else note(a, out, json_lines, "info", "workspace {s}: {d} free bytes; this file system does not count inodes", .{ path, free.bytes });
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
/// A kernel setting under /proc/sys, as a number, or null when it cannot be
/// read. Test builds read EB_LOCAL_TEST_PROC_SYS in place of /proc/sys.
fn procSysNumber(c: Ctx, rel: []const u8) ?i64 {
    var root: []const u8 = "/proc/sys";
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_PROC_SYS"))) |p| root = p;
    }
    const path = std.fs.path.join(c.a, &.{ root, rel }) catch oom();
    const text = readSmall(c.a, path) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\n"), 10) catch null;
}

/// The doctor level for kernel.perf_event_paranoid N: 2 and below let a user
/// sample their own processes; above 2, as some distributions set it, perf
/// needs privileges.
fn perfParanoidLevel(n: i64) []const u8 {
    return if (n <= 2) "ok  " else "warn";
}

/// The doctor level for kernel.yama.ptrace_scope N: 0 lets a debugger attach
/// to any of the user's processes, 1 only to its own children, 2 and 3 to
/// none without privileges.
fn ptraceScopeLevel(n: i64) []const u8 {
    return switch (n) {
        0 => "ok  ",
        1 => "info",
        else => "warn",
    };
}

fn reportProfiling(c: Ctx, out: *std.ArrayList(u8), json_lines: ?*std.ArrayList(DoctorLine)) void {
    const a = c.a;
    if (procSysNumber(c, "kernel/perf_event_paranoid")) |n| {
        if (n <= 2) {
            note(a, out, json_lines, perfParanoidLevel(n), "perf can sample your own processes (kernel.perf_event_paranoid {d})", .{n});
        } else note(a, out, json_lines, perfParanoidLevel(n), "perf cannot sample unprivileged processes (kernel.perf_event_paranoid {d}); ask the administrators for 2 or less", .{n});
    } else note(a, out, json_lines, "info", "kernel.perf_event_paranoid cannot be read", .{});
    if (procSysNumber(c, "kernel/yama/ptrace_scope")) |n| {
        const level = ptraceScopeLevel(n);
        switch (n) {
            0 => note(a, out, json_lines, level, "debuggers can attach to your running processes (kernel.yama.ptrace_scope 0)", .{}),
            1 => note(a, out, json_lines, level, "gdb and other debuggers can start a program but not attach to a running one you did not start under them (kernel.yama.ptrace_scope 1)", .{}),
            else => note(a, out, json_lines, level, "debuggers cannot attach to processes without privileges (kernel.yama.ptrace_scope {d}); starting a program under valgrind still works", .{n}),
        }
    } else note(a, out, json_lines, "info", "no Yama ptrace restriction", .{});
    const path_env = c.env.get("PATH") orelse "";
    for ([_][]const u8{ "perf", "valgrind", "gdb" }) |name| {
        if (proc.which(a, name, path_env) catch null) |exe| {
            note(a, out, json_lines, "ok  ", "{s}: {s}", .{ name, exe });
        } else note(a, out, json_lines, "info", "{s} is not on PATH; `module spider {s}` finds a module where the stack has one", .{ name, name });
    }
}

test "profiling levels follow the kernel settings" {
    try std.testing.expectEqualStrings("ok  ", perfParanoidLevel(-1));
    try std.testing.expectEqualStrings("ok  ", perfParanoidLevel(2));
    try std.testing.expectEqualStrings("warn", perfParanoidLevel(3));
    try std.testing.expectEqualStrings("warn", perfParanoidLevel(4));
    try std.testing.expectEqualStrings("ok  ", ptraceScopeLevel(0));
    try std.testing.expectEqualStrings("info", ptraceScopeLevel(1));
    try std.testing.expectEqualStrings("warn", ptraceScopeLevel(2));
    try std.testing.expectEqualStrings("warn", ptraceScopeLevel(3));
}

test "variant blocks are known by name only" {
    try std.testing.expect(std.mem.indexOf(u8, variantBlock("perf").?, "-fno-omit-frame-pointer") != null);
    try std.testing.expect(std.mem.endsWith(u8, variantBlock("perf").?, "+ '-perf'"));
    try std.testing.expect(std.mem.indexOf(u8, variantBlock("debug").?, "toolchainopts['noopt'] = True") != null);
    try std.testing.expect(std.mem.endsWith(u8, variantBlock("debug").?, "+ '-debug'"));
    try std.testing.expect(variantBlock("asan") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_script_tail, "EB_LOCAL_VARIANT_BLOCK") != null);
}

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
    const local = localStorage(s, c, g);
    const site = s.node_local_root.value.len > 0;
    if (local) {
        note(a, &out, lines_ptr, "ok  ", "builds use a private workspace on this workstation's local disk", .{});
    } else if (site) {
        note(a, &out, lines_ptr, "ok  ", "builds use the allocation's own {s} mount {s}/{s}", .{ s.node_local_fstype.value, s.node_local_root.value, s.node_local_mount.value });
    } else {
        note(a, &out, lines_ptr, "info", "no workspace storage is configured for this Slurm job; set storage.node_local_root or storage.mode = \"local\"", .{});
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
    // The prefix is already canonical. Include the resolved roots a build
    // refuses, and report a path once when the written form and the resolved
    // form are the same directory.
    var reported: std.ArrayList([]const u8) = .empty;
    for (refusedTrees(c, s, true)) |t| {
        if (t.path.len == 0 or !storage.under(p.prefix, t.path)) continue;
        const seen = for (reported.items) |old| {
            if (std.mem.eql(u8, old, t.path)) break true;
        } else false;
        if (seen) continue;
        reported.append(a, t.path) catch oom();
        note(a, &out, lines_ptr, "FAIL", "the install prefix {s} [{s}] is under {s}, {s}; builds refuse it. " ++ outlive ++ "; " ++ prefix_fix, .{ p.prefix, prefixFrom(s, p), t.path, t.what });
        failed = true;
    }
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
            if (cap.exhausted()) {
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
                if (cap.exhausted()) {
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
            } else {
                const configured = configuredInstall(p);
                if (matchesConfiguredInstall(c, configured, sel, v)) {
                    note(a, &out, lines_ptr, "ok  ", "`eb-local eb` makes a {s} install: {s}={s}", .{ @tagName(sel.mode), name, q(a, v) });
                } else {
                    note(a, &out, lines_ptr, "warn", "`eb-local eb` keeps explicitly exported {s}={s}, a {s} install that does not match configured {s}={s}; unset {s} to use configuration", .{
                        name,
                        q(a, v),
                        @tagName(sel.mode),
                        configured.variable(),
                        q(a, configured.prefix),
                        name,
                    });
                }
            }
        } else {
            const install = configuredInstall(p);
            note(a, &out, lines_ptr, "ok  ", "`eb-local eb` exports {s}={s}, the {s} selected by configuration", .{
                install.variable(),
                q(a, install.prefix),
                install.setting(),
            });
        }
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
    if (local) {
        const lr = checkedLocalRoot(c, s, "doctor checks no further", false);
        if (lr.refused_reason) |why| {
            note(a, &out, lines_ptr, "FAIL", "{s}; builds refuse it", .{why});
            failed = true;
        } else if (lr.refused_fstype) |fstype| {
            note(a, &out, lines_ptr, "FAIL", "workstation workspace directory {s} is on {s}, which is memory-backed, network or shared storage; builds refuse it. Set XDG_CACHE_HOME to a directory on this workstation's local disk", .{ lr.path, fstype });
            failed = true;
        } else if (workspaceCapacityOverride(c) orelse storage.capacity(lr.capacity_path) catch null) |cap| {
            if (cap.exhausted()) {
                note(a, &out, lines_ptr, "FAIL", "workstation build space {s} has no space left on device ({d} free bytes, {d} free inodes)", .{ lr.path, cap.bytes, cap.inodes });
                failed = true;
            } else if (cap.inodes_counted) {
                note(a, &out, lines_ptr, "ok  ", "workstation build space {s}: {d} free bytes, {d} free inodes", .{ lr.path, cap.bytes, cap.inodes });
            } else note(a, &out, lines_ptr, "ok  ", "workstation build space {s}: {d} free bytes; this file system does not count inodes", .{ lr.path, cap.bytes });
        } else {
            note(a, &out, lines_ptr, "FAIL", "workstation build space {s}: free bytes and inodes cannot be read", .{lr.path});
            failed = true;
        }
    } else if (nonEmpty(c.env.get("SLURM_JOB_ID"))) |job| {
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
        // A build sources each readable initializer and keeps going until
        // one defines the module command. Reading the file is not enough.
        var env = c.env.clone(a) catch oom();
        for (shell_startup) |name| _ = env.swapRemove(name);
        const envp = envpOf(a, &env);
        var defined: ?[]const u8 = null;
        var any_readable = false;
        for (inits) |file| {
            if (!readable(file)) continue;
            any_readable = true;
            if (initDefinesModule(c, envp, file)) {
                defined = file;
                break;
            }
        }
        if (defined) |file| {
            note(a, &out, lines_ptr, "info", "no module command in this shell; builds source {s}", .{file});
        } else if (!any_readable) {
            note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "no module command in this shell, and none of {s}, {s} or {s} can be read; builds stop there, and the module commands env and dev print do not run", .{ inits[0], inits[1], inits[2] });
            if (site) failed = true;
        } else {
            note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "no module command in this shell, and none of {s}, {s} or {s} defined one; builds stop there, and the module commands env and dev print do not run", .{ inits[0], inits[1], inits[2] });
            if (site) failed = true;
        }
    } else if (!onModulePath(a, c.env.get("MODULEPATH") orelse "", s.stack_module.value)) {
        // A build keeps the shell's module command, and with it MODULEPATH,
        // and sources no init that would put EESSI's modules there; it adds
        // EESSI's module directory when that holds the stack.
        const repo = nonEmpty(c.env.get("EESSI_CVMFS_REPO")) orelse "/cvmfs/software.eessi.io";
        const eessi_dir = std.fs.path.join(a, &.{ repo, "init", "modules" }) catch oom();
        if (onModulePath(a, eessi_dir, s.stack_module.value)) {
            note(a, &out, lines_ptr, "info", "no directory on MODULEPATH in this shell holds stack.module, {s} [{s}]; builds, env and dev add {s}, which does", .{ s.stack_module.value, s.stack_module.from, eessi_dir });
        } else {
            note(a, &out, lines_ptr, if (site) "FAIL" else "warn", "no directory on MODULEPATH in this shell holds stack.module, {s} [{s}], so builds, env and dev cannot load it; module use {s}/init/modules adds EESSI's module directory", .{ s.stack_module.value, s.stack_module.from, repo });
            if (site) failed = true;
        }
    }
    if (proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null) |_| {
        note(a, &out, lines_ptr, "ok  ", "rtrash is on PATH: clean and uninstall move files to the trash", .{});
    } else note(a, &out, lines_ptr, "warn", "rtrash is not on PATH: clean and uninstall remove nothing unless given --delete", .{});

    if (opts.cvmfs) {
        const tasks = opts.parallel orelse s.cvmfs_parallel.value;
        if (reportCvmfs(c, tasks, &out, lines_ptr)) failed = true;
    }
    if (opts.mpi) reportMpi(c, s, &out, lines_ptr);
    if (opts.profiling) reportProfiling(c, &out, lines_ptr);
    if (opts.cpu_target) |t| reportCpuTarget(c, t, &out, lines_ptr);
    if (opts.workspace) |workspace| {
        if (reportWorkspace(c, s, workspace, &out, lines_ptr)) failed = true;
    }

    const warned = hasDoctorWarning(out.items, json_lines.items, g.json_out);
    const strict_fail = opts.strict and warned;
    const any_failed = failed or strict_fail;
    const managed_build = site or local;
    const summary = if (failed)
        (if (managed_build) "Something above says FAIL; builds stop there." else "Something above says FAIL; `eb-local eb` stops there, and `eb-local RECIPE` needs a site file.")
    else if (strict_fail)
        "Something above says warn (--strict); warnings fail under --strict."
    else if (managed_build)
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
    if (!emit(out.items)) return 1;
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

/// Append the global options that selected this configuration.
fn appendConfigurationOptions(c: Ctx, s: config.Settings, g: Global, p: Place, line: *std.ArrayList([]const u8)) void {
    const a = c.a;
    if (g.config_file) |f| line.appendSlice(a, &.{ "--config", qSingleLine(a, storage.canonical(a, f, c.cwd) catch oom()) }) catch oom();
    if (s.profile) |pr| line.appendSlice(a, &.{ "--profile", qSingleLine(a, pr) }) catch oom();
    if (p.project) line.appendSlice(a, &.{ "--project", qSingleLine(a, p.prefix) }) catch oom();
    if (g.variant) |v| line.appendSlice(a, &.{ "--variant", v }) catch oom();
    line.appendSlice(a, maskOptionWords(a, g)) catch oom();
}

/// `--cpu-target`, `--mask` and `--no-audit` as the command line that
/// reproduces them, empty without a target.
fn maskOptionWords(a: Allocator, g: Global) []const []const u8 {
    const t = g.cpu_target orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(a, &.{ "--cpu-target", qSingleLine(a, t) }) catch oom();
    if (g.mask != .auto) out.appendSlice(a, &.{ "--mask", @tagName(g.mask) }) catch oom();
    if (g.no_audit) out.append(a, "--no-audit") catch oom();
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
    appendConfigurationOptions(c, s, g, p, &line);
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
    if (std.mem.indexOfAny(u8, v, "\n\r") != null)
        die("#SBATCH directive value {s} has a newline; #SBATCH directives are single lines", .{qSingleLine(a, v)});
    if (std.mem.indexOfAny(u8, v, " \t\"\\") == null) return v;
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
    if (std.mem.indexOfAny(u8, p.prefix, "\n\r") != null)
        die("installation prefix {s} has a newline; #SBATCH directives are single lines", .{qSingleLine(a, p.prefix)});
    if (std.mem.indexOfAny(u8, c.cwd, "\n\r") != null)
        die("working directory {s} has a newline; #SBATCH directives are single lines", .{qSingleLine(a, c.cwd)});
    const sbatch = (proc.which(a, "sbatch", c.env.get("PATH") orelse "") catch null) orelse
        if (o.print) "sbatch" else die("sbatch is not on PATH", .{});
    const command = jobCommand(c, s, g, p, args);

    const root = std.fs.path.join(a, &.{ p.prefix, ".eb-local" }) catch oom();
    const jobs = std.fs.path.join(a, &.{ root, "jobs" }) catch oom();
    const logs = std.fs.path.join(a, &.{ root, "logs" }) catch oom();
    const recipe = jobNamePart(a, std.fs.path.basename(args[0]));
    const stamp = submitStamp(a, c);
    var plan: std.ArrayList(SubmitJob) = .empty;
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
        const preferred = std.fs.path.join(a, &.{ jobs, str(a, "{s}-{s}-{s}.sh", .{ stamp, t.name, recipe }) }) catch oom();
        // `--print` only stats. A real submit reserves below, and the plan
        // names that reserved path.
        const path = if (o.print) chooseSubmitPath(a, preferred) else "";
        const argv: []const []const u8 = if (o.print) submitArgv(a, sbatch, t.sbatch, path) else &.{};
        plan.append(a, .{
            .name = t.name,
            .script = script,
            .preferred = preferred,
            .options = t.sbatch,
            .path = path,
            .argv = argv,
        }) catch oom();
    }
    if (o.print) {
        for (plan.items) |job| {
            say("# {s}: {s}", .{ job.name, std.mem.join(a, " ", job.argv) catch oom() });
            if (!emit(job.script)) return 1;
        }
        return 0;
    }
    // Reserve each final path before the plan is printed. The line then
    // names the file sbatch receives, including a -2, -3, ... suffix when
    // the preferred name is taken. The body is written after the plan.
    const jobs_missing = firstMissingAncestor(jobs);
    const logs_missing = firstMissingAncestor(logs);
    common.atomic.makedirs(jobs) catch |e| die("cannot create {s} ({s})", .{ jobs, storage.describeError(e) });
    common.atomic.makedirs(logs) catch |e| die("cannot create {s} ({s})", .{ logs, storage.describeError(e) });
    var fault: SubmitFault = .{ .kind = .create, .path = jobs, .err = error.Unexpected };
    if (submitReserved(c, plan.items, sbatch, jobs, logs, jobs_missing, logs_missing, &fault)) |status| {
        return status;
    } else |err| switch (err) {
        error.PlanNotPrinted => return unlisted("submitted"),
        error.OutOfMemory => oom(),
        error.SubmitFailed => raiseSubmitFault(fault),
    }
}

/// The stamp in a retained submit script's name. The test artifact may pin
/// it, so a collision can be forced; a release build always uses seconds and
/// the process id.
fn submitStamp(a: Allocator, c: Ctx) []const u8 {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_SUBMIT_STAMP"))) |s| {
            if (std.mem.indexOfAny(u8, s, "/\x00") == null) return s;
        }
    }
    return str(a, "{d}.{d}", .{ nowSecs(), linux.getpid() });
}

/// A free path for `--print`, which must not create a file. A real submit
/// reserves with `reserveSubmitScript` instead, so the printed name is the
/// file that was created.
fn chooseSubmitPath(a: Allocator, preferred: []const u8) []const u8 {
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const path = if (n == 0) preferred else submitScriptSuffix(a, preferred, n + 1);
        if (!exists(path)) return path;
    }
    die("cannot write {s}: the name and its suffixes are already taken", .{preferred});
}

/// `sbatch` plus its options and the script path, as separate words.
fn submitArgv(a: Allocator, sbatch: []const u8, options: []const u8, path: []const u8) []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, sbatch) catch oom();
    var words = std.mem.tokenizeScalar(u8, options, ' ');
    while (words.next()) |w| argv.append(a, w) catch oom();
    argv.append(a, path) catch oom();
    return argv.items;
}

/// `preferred` with `-N` before a trailing `.sh`, for the Nth collision.
fn submitScriptSuffix(a: Allocator, path: []const u8, n: usize) []const u8 {
    if (std.mem.endsWith(u8, path, ".sh"))
        return str(a, "{s}-{d}.sh", .{ path[0 .. path.len - 3], n });
    return str(a, "{s}-{d}", .{ path, n });
}

/// The nearest missing ancestor of `path`, including `path` when it is missing.
fn firstMissingAncestor(path: []const u8) ?[]const u8 {
    var probe: []const u8 = path;
    var missing: ?[]const u8 = null;
    while (probe.len > 1) {
        if (exists(probe)) break;
        missing = probe;
        probe = std.fs.path.dirname(probe) orelse break;
    }
    return missing;
}

fn pathCovers(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    return child.len > parent.len and child[parent.len] == '/' and std.mem.startsWith(u8, child, parent);
}

const SubmitJob = struct {
    name: []const u8,
    script: []const u8,
    preferred: []const u8,
    options: []const u8,
    path: []const u8,
    argv: []const []const u8,
};

const SubmitFault = struct {
    kind: enum { create, mode, taken, open, write, start },
    path: []const u8,
    err: anyerror,
};

fn raiseSubmitFault(f: SubmitFault) noreturn {
    switch (f.kind) {
        .create => die("cannot create {s} ({s})", .{ f.path, storage.describeError(f.err) }),
        .mode => die("cannot set the mode of {s} ({s})", .{ f.path, storage.describeError(f.err) }),
        .taken => die("cannot write {s}: the name and its suffixes are already taken", .{f.path}),
        .open => die("cannot open {s} ({s})", .{ f.path, storage.describeError(f.err) }),
        .write => die("cannot write {s} ({s})", .{ f.path, storage.describeError(f.err) }),
        .start => die("cannot start {s}", .{f.path}),
    }
}

const ExclusiveOpen = union(enum) {
    fd: sys.fd_t,
    busy,
    fail: SubmitFault,
};

/// Reserve, write, and submit `plan`. An error removes every script this
/// call reserved and has not handed to sbatch. `error.PlanNotPrinted` also
/// removes directories this call created, and only those.
fn submitReserved(
    c: Ctx,
    plan: []SubmitJob,
    sbatch: []const u8,
    jobs_dir: []const u8,
    logs_dir: []const u8,
    jobs_missing: ?[]const u8,
    logs_missing: ?[]const u8,
    fault: *SubmitFault,
) error{ SubmitFailed, PlanNotPrinted, OutOfMemory }!u8 {
    const a = c.a;
    var handed: usize = 0;
    var rollback_dirs = false;
    var created: std.ArrayList([]const u8) = .empty;
    errdefer {
        // Cleanup runs before the failure is described. A failed unlink
        // must not replace the errno of the write, sync or close.
        const kept = sys.last_errno;
        defer sys.last_errno = kept;
        if (rollback_dirs) {
            undoSubmitReserve(a, jobs_dir, logs_dir, jobs_missing, logs_missing, created.items);
        } else {
            dropUnsubmitted(plan, handed);
            if (handed == 0) {
                for (created.items) |p| sys.unlinkat(fsx.cwd, p, 0) catch {};
            }
        }
    }
    for (plan) |*job| {
        if (plantSubmitRace(c, job.preferred)) |planted| created.append(a, planted) catch return error.OutOfMemory;
        job.path = reserveSubmitScript(a, job.preferred, fault) catch return error.SubmitFailed;
        created.append(a, job.path) catch return error.OutOfMemory;
        job.argv = submitArgv(a, sbatch, job.options, job.path);
    }
    {
        var plan_text: std.ArrayList(u8) = .empty;
        for (plan) |job| {
            const line = std.mem.join(a, " ", job.argv) catch return error.OutOfMemory;
            plan_text.print(a, "eb-local: {s}: {s}\n", .{ job.name, line }) catch return error.OutOfMemory;
        }
        if (!emit(plan_text.items)) {
            rollback_dirs = true;
            return error.PlanNotPrinted;
        }
    }
    var failed = false;
    const guard = Guard.hold();
    defer guard.release();
    for (plan, 0..) |job, index| {
        if (guard.received()) |sig| {
            dropUnsubmitted(plan, index);
            guard.release();
            return stop(.{ .signal = sig });
        }
        writeReservedScript(job.path, job.script, fault) catch return error.SubmitFailed;
        if (guard.received()) |sig| {
            dropUnsubmitted(plan, index);
            guard.release();
            return stop(.{ .signal = sig });
        }
        const ran = guard.run(a, job.argv, c.envp) catch {
            fault.* = .{ .kind = .start, .path = job.argv[0], .err = error.Unexpected };
            return error.SubmitFailed;
        };
        switch (ran) {
            .exit => |code| {
                if (code != 0) {
                    if (guard.received()) |sig| {
                        dropUnsubmitted(plan, index);
                        guard.release();
                        return stop(.{ .signal = sig });
                    }
                    warn("sbatch refused the {s} job (exit {d})", .{ job.name, code });
                    failed = true;
                }
                // sbatch ran. This script stays, including when sbatch refused it.
                handed = index + 1;
                if (guard.received()) |sig| {
                    dropUnsubmitted(plan, index + 1);
                    guard.release();
                    return stop(.{ .signal = sig });
                }
            },
            .signal => |sig| {
                dropUnsubmitted(plan, index);
                guard.release();
                return stop(.{ .signal = guard.received() orelse sig });
            },
            .unreaped => {
                failed = true;
            },
        }
    }
    if (guard.received()) |sig| {
        guard.release();
        return stop(.{ .signal = sig });
    }
    say("", .{});
    say("eb-local: each job writes {s}/submit-TARGET-JOBID.out; eb-local list shows the result per target.", .{logs_dir});
    return if (failed) 1 else 0;
}

/// Drop reserved scripts and directories this call created for a plan that
/// was not printed. Only this call's files are unlinked. Directories it
/// created are removed with `rmdir`, deepest first, and a directory that
/// another submit has filled is left in place.
fn undoSubmitReserve(
    a: Allocator,
    jobs_dir: []const u8,
    logs_dir: []const u8,
    jobs_missing: ?[]const u8,
    logs_missing: ?[]const u8,
    created: []const []const u8,
) void {
    for (created) |p| sys.unlinkat(fsx.cwd, p, 0) catch {};
    removeCreatedSubmitDirs(a, jobs_dir, logs_dir, jobs_missing, logs_missing);
}

/// Directories this call created, deepest first. Each removal is `rmdir`:
/// `ENOTEMPTY` leaves the directory and whatever another submit put in it.
/// This never walks the directory.
fn removeCreatedSubmitDirs(
    a: Allocator,
    jobs_dir: []const u8,
    logs_dir: []const u8,
    jobs_missing: ?[]const u8,
    logs_missing: ?[]const u8,
) void {
    var dirs: std.ArrayList([]const u8) = .empty;
    appendCreatedChain(a, &dirs, jobs_dir, jobs_missing);
    appendCreatedChain(a, &dirs, logs_dir, logs_missing);
    std.mem.sort([]const u8, dirs.items, {}, deeperPath);
    for (dirs.items) |dir| sys.unlinkat(fsx.cwd, dir, linux.AT.REMOVEDIR) catch {};
}

fn deeperPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return lhs.len > rhs.len;
}

fn appendCreatedChain(a: Allocator, dirs: *std.ArrayList([]const u8), target: []const u8, top: ?[]const u8) void {
    const root = top orelse return;
    var probe: []const u8 = target;
    while (pathCovers(root, probe)) {
        var seen = false;
        for (dirs.items) |have| {
            if (std.mem.eql(u8, have, probe)) {
                seen = true;
                break;
            }
        }
        if (!seen) dirs.append(a, probe) catch oom();
        if (std.mem.eql(u8, probe, root)) break;
        probe = std.fs.path.dirname(probe) orelse break;
    }
}

/// Unlink reserved scripts from `from` on. Those jobs were not submitted.
fn dropUnsubmitted(jobs: anytype, from: usize) void {
    if (from >= jobs.len) return;
    for (jobs[from..]) |job| {
        if (job.path.len == 0) continue;
        sys.unlinkat(fsx.cwd, job.path, 0) catch {};
    }
}

/// Create an empty `path` with mode 0700. `busy` when that final path already
/// exists, is a directory, or is a symbolic link: the caller then tries
/// another name. `O_EXCL` is what makes the collision visible.
fn openExclusive(path: []const u8) ExclusiveOpen {
    const fd = sys.openat(fsx.cwd, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, 0o700) catch |e| switch (e) {
        error.Exists, error.SymLink, error.IsDir => return .busy,
        else => return .{ .fail = .{ .kind = .create, .path = path, .err = e } },
    };
    sys.fchmod(fd, 0o700) catch |e| {
        sys.close(fd);
        sys.unlinkat(fsx.cwd, path, 0) catch {};
        return .{ .fail = .{ .kind = .mode, .path = path, .err = e } };
    };
    return .{ .fd = fd };
}

/// Create `path` and write `body` with mode 0700. False when that final path
/// already exists, is a directory, or is a symbolic link.
fn createExclusiveScript(path: []const u8, body: []const u8) bool {
    switch (openExclusive(path)) {
        .busy => return false,
        .fail => |f| raiseSubmitFault(f),
        .fd => |fd| {
            sys.writeAll(fd, body) catch |e| {
                sys.close(fd);
                sys.unlinkat(fsx.cwd, path, 0) catch {};
                die("cannot write {s} ({s})", .{ path, storage.describeError(e) });
            };
            sys.close(fd);
            return true;
        },
    }
}

/// Reserve `preferred`, or that path with a `-2`, `-3`, ... suffix, with
/// `O_EXCL` and mode 0700. The file is empty until `writeReservedScript`.
/// An earlier job's script is never replaced.
fn reserveSubmitScript(a: Allocator, preferred: []const u8, fault: *SubmitFault) error{SubmitFailed}![]const u8 {
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const path = if (n == 0) preferred else submitScriptSuffix(a, preferred, n + 1);
        switch (openExclusive(path)) {
            .busy => {},
            .fd => |fd| {
                sys.close(fd);
                return path;
            },
            .fail => |f| {
                fault.* = f;
                return error.SubmitFailed;
            },
        }
    }
    fault.* = .{ .kind = .taken, .path = preferred, .err = error.Unexpected };
    return error.SubmitFailed;
}

/// Write `body` into a file `reserveSubmitScript` already created.
/// The bytes are synced and the close is checked. NFS reports a lost
/// write from those calls, so either failure is `error.SubmitFailed`
/// and the script is not handed to sbatch.
fn writeReservedScript(path: []const u8, body: []const u8, fault: *SubmitFault) error{SubmitFailed}!void {
    const fd = sys.openat(fsx.cwd, path, .{
        .ACCMODE = .WRONLY,
        .TRUNC = true,
        .NOFOLLOW = true,
    }, 0) catch |e| {
        fault.* = .{ .kind = .open, .path = path, .err = e };
        return error.SubmitFailed;
    };
    sys.writeAll(fd, body) catch |e| {
        sys.close(fd);
        fault.* = .{ .kind = .write, .path = path, .err = e };
        return error.SubmitFailed;
    };
    storage.fsyncWritten(fd) catch |e| {
        sys.close(fd);
        fault.* = .{ .kind = .write, .path = path, .err = e };
        return error.SubmitFailed;
    };
    storage.closeWritten(fd) catch |e| {
        fault.* = .{ .kind = .write, .path = path, .err = e };
        return error.SubmitFailed;
    };
}

/// Write `script` at `preferred`, or at that path with a `-2`, `-3`, ...
/// suffix when the final path is already taken. An earlier job's script is
/// never replaced.
fn retainSubmitScript(a: Allocator, preferred: []const u8, script: []const u8) []const u8 {
    var fault: SubmitFault = undefined;
    const path = reserveSubmitScript(a, preferred, &fault) catch raiseSubmitFault(fault);
    writeReservedScript(path, script, &fault) catch {
        const kept = sys.last_errno;
        sys.unlinkat(fsx.cwd, path, 0) catch {};
        sys.last_errno = kept;
        raiseSubmitFault(fault);
    };
    return path;
}

/// Test builds only. Plant `preferred` before the exclusive create: another
/// process took that name after a stat and before `O_EXCL`. Returns the
/// planted path when this call created it.
fn plantSubmitRace(c: Ctx, preferred: []const u8) ?[]const u8 {
    if (comptime !build_options.test_ops) return null;
    const flag = nonEmpty(c.env.get("EB_LOCAL_TEST_SUBMIT_RACE")) orelse return null;
    if (std.mem.indexOfAny(u8, flag, "/\x00") != null) return null;
    if (exists(preferred)) return null;
    if (!createExclusiveScript(preferred, "#!/bin/bash\n# raced\n")) return null;
    return preferred;
}

fn readRetainedScript(a: Allocator, path: []const u8) ![]const u8 {
    const opened = try fsx.openRegular(fsx.cwd, path, true);
    defer sys.close(opened.fd);
    return fsx.readAll(a, opened.fd, 1 << 16);
}

test "a forced collision keeps both retained submit scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/submit-collision-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(std.testing.allocator, fsx.cwd, root) catch {};
    try common.atomic.makedirs(root);
    const preferred = try std.fmt.allocPrint(a, "{s}/1700000000.42-cpu-recipe.sh", .{root});
    const first = retainSubmitScript(a, preferred, "#!/bin/bash\n# first\n");
    const second = retainSubmitScript(a, preferred, "#!/bin/bash\n# second\n");
    try std.testing.expectEqualStrings(preferred, first);
    const suffixed = try std.fmt.allocPrint(a, "{s}/1700000000.42-cpu-recipe-2.sh", .{root});
    try std.testing.expectEqualStrings(suffixed, second);
    try std.testing.expectEqualStrings("#!/bin/bash\n# first\n", try readRetainedScript(a, first));
    try std.testing.expectEqualStrings("#!/bin/bash\n# second\n", try readRetainedScript(a, second));
    const st = try fsx.statAt(fsx.cwd, first, false);
    try std.testing.expectEqual(@as(u32, 0o700), st.perm());
}

test "a candidate created between the stat and the exclusive create is not submitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/submit-race-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(std.testing.allocator, fsx.cwd, root) catch {};
    try common.atomic.makedirs(root);
    const preferred = try std.fmt.allocPrint(a, "{s}/1700000000.42-cpu-recipe.sh", .{root});
    const chosen = chooseSubmitPath(a, preferred);
    try std.testing.expectEqualStrings(preferred, chosen);
    try std.testing.expect(createExclusiveScript(preferred, "#!/bin/bash\n# raced\n"));
    var fault: SubmitFault = .{ .kind = .create, .path = preferred, .err = error.Unexpected };
    const reserved = try reserveSubmitScript(a, preferred, &fault);
    const suffixed = try std.fmt.allocPrint(a, "{s}/1700000000.42-cpu-recipe-2.sh", .{root});
    try std.testing.expectEqualStrings(suffixed, reserved);
    const script = "#!/bin/bash\n# second\n";
    try writeReservedScript(reserved, script, &fault);
    try std.testing.expectEqualStrings(reserved, suffixed);
    try std.testing.expectEqualStrings("#!/bin/bash\n# raced\n", try readRetainedScript(a, preferred));
    try std.testing.expectEqualStrings(script, try readRetainedScript(a, reserved));
    const st = try fsx.statAt(fsx.cwd, reserved, false);
    try std.testing.expectEqual(@as(u32, 0o700), st.perm());
}

test "failure after reservation leaves no reserved files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/submit-reserve-fail-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(std.testing.allocator, fsx.cwd, root) catch {};
    try common.atomic.makedirs(root);
    const keep = try std.fmt.allocPrint(a, "{s}/keep.txt", .{root});
    try std.testing.expect(createExclusiveScript(keep, "foreign\n"));
    const first = try std.fmt.allocPrint(a, "{s}/job.sh", .{root});
    const second = try std.fmt.allocPrint(a, "{s}/job.sh/next.sh", .{root});
    var jobs = [_]SubmitJob{
        .{ .name = "cpu", .script = "#!/bin/bash\n", .preferred = first, .options = "", .path = "", .argv = &.{} },
        .{ .name = "gpu", .script = "#!/bin/bash\n", .preferred = second, .options = "", .path = "", .argv = &.{} },
    };
    var map: std.process.Environ.Map = .init(a);
    const c: Ctx = .{ .a = a, .io = std.testing.io, .env = &map, .envp = envpOf(a, &map), .cwd = root };
    var fault: SubmitFault = .{ .kind = .create, .path = first, .err = error.Unexpected };
    try std.testing.expectError(error.SubmitFailed, submitReserved(c, &jobs, "sbatch", root, root, null, null, &fault));
    try std.testing.expect(!exists(first));
    try std.testing.expect(!exists(second));
    try std.testing.expectEqualStrings("foreign\n", try readRetainedScript(a, keep));
    try std.testing.expect(exists(root));
}

test "rollback with a foreign file in a newly created directory keeps that file and directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/submit-rollback-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(std.testing.allocator, fsx.cwd, root) catch {};
    try common.atomic.makedirs(root);
    const jobs = try std.fmt.allocPrint(a, "{s}/fresh/jobs", .{root});
    const logs = try std.fmt.allocPrint(a, "{s}/fresh/logs", .{root});
    const jobs_missing = firstMissingAncestor(jobs);
    const logs_missing = firstMissingAncestor(logs);
    try common.atomic.makedirs(jobs);
    try common.atomic.makedirs(logs);
    const own = try std.fmt.allocPrint(a, "{s}/own.sh", .{jobs});
    const kept = try std.fmt.allocPrint(a, "{s}/foreign.sh", .{jobs});
    try std.testing.expect(createExclusiveScript(kept, "theirs\n"));
    var plan = [_]SubmitJob{
        .{ .name = "cpu", .script = "#!/bin/bash\n", .preferred = own, .options = "", .path = "", .argv = &.{} },
    };
    var map: std.process.Environ.Map = .init(a);
    const c: Ctx = .{ .a = a, .io = std.testing.io, .env = &map, .envp = envpOf(a, &map), .cwd = root };
    const saved = stdout;
    const full_fd = try sys.openat(linux.AT.FDCWD, "/dev/full", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    defer sys.close(full_fd);
    const quiet = try sys.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    defer sys.close(quiet);
    stdout = .{ .tool = tool, .fd = full_fd, .err_fd = quiet };
    defer stdout = saved;
    var fault: SubmitFault = .{ .kind = .create, .path = own, .err = error.Unexpected };
    try std.testing.expectError(error.PlanNotPrinted, submitReserved(c, &plan, "/no/such/sbatch", jobs, logs, jobs_missing, logs_missing, &fault));
    try std.testing.expect(!exists(own));
    try std.testing.expectEqualStrings("theirs\n", try readRetainedScript(a, kept));
    try std.testing.expect(exists(jobs));
    try std.testing.expect(!exists(logs));
    const fresh = try std.fmt.allocPrint(a, "{s}/fresh", .{root});
    try std.testing.expect(exists(fresh));
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

/// What `uninstall` would remove, or null after it has said why it removes
/// nothing, which is exit status 2.
fn uninstallPlan(c: Ctx, p: Place, versions: []const u8, modules: []const []const u8, o: UninstallOpts) ?Found {
    const a = c.a;
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
        return null;
    }
    // The usage log is eb-keep-logs' to read. Exit 2 from
    // `used --require-none` means the prefix is named there, or the log
    // could not be read; either way nothing is removed. Without the
    // option this is not consulted.
    if (o.usage_log) |log| if (usageRefuses(c, p.prefix, log)) return null;
    return found;
}

/// Whether `now` names exactly what `self` names. A module file or link added
/// since is not listed, so removing the installation would leave it dangling.
fn foundUnchanged(self: Found, now: Found) bool {
    for ([_][2][]const []const u8{
        .{ self.installs.items, now.installs.items },
        .{ self.modules.items, now.modules.items },
    }) |pair| {
        for (pair[0]) |x| if (!listed(pair[1], x)) return false;
        for (pair[1]) |y| if (!listed(pair[0], y)) return false;
    }
    return true;
}

fn cmdUninstall(c: Ctx, s: config.Settings, modules: []const []const u8, o: UninstallOpts) u8 {
    const a = c.a;
    if (modules.len == 0) die("uninstall needs NAME/VERSION, as module avail shows it", .{});
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |st| {
        if (st.isLink() or !literalPath(c, versions)) die("{s} is reached through a symbolic link; uninstall leaves it alone.", .{versions});
    } else |_| die("nothing is installed in {s}", .{p.prefix});
    const found = uninstallPlan(c, p, versions, modules, o) orelse return 2;
    for (found.installs.items) |d| {
        if (!storage.under(d, versions)) die("{s} is outside {s}", .{ d, versions });
        say("  {s}/", .{d});
    }
    for (found.modules.items) |f| say("  {s}", .{f});
    if (stdout.failed) return unlisted("removed");
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
    // The list is out. Only now does uninstall take the prefix lock, which
    // makes `.eb-local/.lock`, and check under it that what it listed is
    // still installed and still safe to remove.
    var prefix_lock: ?sys.fd_t = acquirePrefixLock(c, p.prefix);
    defer storage.releaseLockAfterError(&prefix_lock);
    const again = uninstallPlan(c, p, versions, modules, o) orelse return 2;
    if (!foundUnchanged(found, again)) {
        warn("what uninstall listed changed while it waited for the prefix lock; nothing was removed. Run it again.", .{});
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
                    storage.releaseLockAfterError(&prefix_lock);
                    return stop(run);
                },
                .unreaped => return 1,
            }
        }
    } else {
        for (found.installs.items) |d| fsx.deleteTree(a, fsx.cwd, d) catch |e| die("cannot remove {s} ({s})", .{ d, storage.describeError(e) });
        for (found.modules.items) |f| sys.unlinkat(fsx.cwd, f, 0) catch |e| die("cannot remove {s} ({s})", .{ f, storage.describeError(e) });
    }
    // The NAME directories they leave empty.
    for ([_][]const []const u8{ found.installs.items, found.modules.items }) |list| for (list) |x| {
        const parent = std.fs.path.dirname(x) orelse continue;
        sys.unlinkat(fsx.cwd, parent, linux.AT.REMOVEDIR) catch {};
    };
    // Nothing is left to change, so this report cannot stop a later step.
    if (trash == .rtrash) {
        say("eb-local: moved {d} installation(s) and {d} module file(s) to the trash (eb-local restore brings them back)", .{ found.installs.items.len, found.modules.items.len });
    } else {
        say("eb-local: deleted {d} installation(s) and {d} module file(s)", .{ found.installs.items.len, found.modules.items.len });
    }
    return endLock(0, &prefix_lock, prefixLockPath(c, p.prefix));
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

/// What `restore` would bring back, in the order it comes back: installations,
/// module files in `modules/all`, and EasyBuild's links to them.
const Restoring = [3]std.ArrayList(Trashed);

fn restorePlan(c: Ctx, p: Place, versions: []const u8, rtrash: []const u8, modules: []const []const u8) Restoring {
    const a = c.a;
    const entries = trashList(c, rtrash);
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
    return found;
}

/// Whether everything `self` names is still in `now`.
fn restoringHolds(self: Restoring, now: Restoring) bool {
    for (self, 0..) |list, kind| for (list.items) |e| {
        const there = for (now[kind].items) |f| {
            if (std.mem.eql(u8, e.original, f.original) and std.mem.eql(u8, e.trash_dir, f.trash_dir)) break true;
        } else false;
        if (!there) return false;
    };
    return true;
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
    const rtrash = (proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null) orelse
        die("restore brings back what uninstall moved to the trash with rtrash, and rtrash is not on PATH.", .{});
    const found = restorePlan(c, p, versions, rtrash, modules);
    for (found, 0..) |list, kind| for (list.items) |e| say("  {s}{s}", .{ e.original, if (kind == 0) "/" else "" });
    if (stdout.failed) return unlisted("restored");
    if (dry_run) {
        say("eb-local: dry run, nothing restored", .{});
        return 0;
    }
    // The list is out. Only now does restore take the prefix lock, which makes
    // `.eb-local/.lock`, and check under it that the trash still holds what it
    // listed and that nothing is in the way.
    var prefix_lock: ?sys.fd_t = acquirePrefixLock(c, p.prefix);
    defer storage.releaseLockAfterError(&prefix_lock);
    if (!restoringHolds(found, restorePlan(c, p, versions, rtrash, modules))) {
        warn("what restore listed changed while it waited for the prefix lock; nothing was restored. Run it again.", .{});
        return 1;
    }
    // rtrash restore takes no --; every path is absolute.
    for (found, 0..) |list, kind| for (list.items) |e| {
        const run = runAttached(a, &.{ rtrash, "restore", str(a, "--trash-dir={s}", .{e.trash_dir}), e.original }, c.envp);
        switch (run) {
            .exit => |rc| if (rc != 0) die("rtrash restore exited {d}; nothing after {s} was restored", .{ rc, e.original }),
            .signal => {
                storage.releaseLockAfterError(&prefix_lock);
                return stop(run);
            },
            .unreaped => return 1,
        }
        if (kind == 0 and literalPath(c, e.original)) makeReadOnly(c, e.original, 0);
    };
    say("eb-local: restored {d} installation(s), read-only again, and {d} module file(s)", .{ found[0].items.len, found[1].items.len + found[2].items.len });
    return endLock(0, &prefix_lock, prefixLockPath(c, p.prefix));
}

// ---- entry ----------------------------------------------------------------

const Command = enum { build, eb, env, dev, leave, clean, config, profiles, uninstall, restore, site, @"rpath-wrappers", check, list, doctor, @"lmod-cache", modulerc, overlay, submit };

/// The command a word names, other than the default build.
fn subcommand(word: []const u8) ?Command {
    const cmd = std.meta.stringToEnum(Command, word) orelse return null;
    return if (cmd == .build) null else cmd;
}

/// Run the command the arguments name, and return its exit status. With
/// `EB_LOCAL_EESSI_EXTEND` set, not empty and not `0`, every argument is
/// eb's, as for `eb-local eb --`.
pub fn main(init: std.process.Init) u8 {
    return stdout.finish(runMain(init));
}

fn runMain(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    const argv_all = init.minimal.args.toSlice(a) catch die("cannot read the arguments", .{});
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = a.dupe(u8, fsx.realpath(fsx.cwd, ".", &cwd_buf) catch "/") catch oom();
    const c: Ctx = .{ .a = a, .io = init.io, .env = init.environ_map, .envp = init.minimal.environ.block.slice.ptr, .cwd = cwd };
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_STDOUT_WRITES"))) |v| test_stdout_writes = std.fmt.parseInt(usize, v, 10) catch null;
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
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_RELEASE_ERRNO"))) |v| {
            if (std.mem.startsWith(u8, v, "E")) storage.test_release_errno = std.meta.stringToEnum(linux.E, v[1..]);
        }
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_CLOSE_ERRNO"))) |v| storage.test_close_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_CLOSE_AFTER"))) |v| storage.test_close_after = std.fmt.parseInt(u32, v, 10) catch 0;
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_CLOSE_COUNT"))) |v| storage.test_close_count = std.fmt.parseInt(u32, v, 10) catch null;
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_FSYNC_ERRNO"))) |v| storage.test_fsync_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_FSYNC_AFTER"))) |v| storage.test_fsync_after = std.fmt.parseInt(u32, v, 10) catch 0;
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_FSYNC_COUNT"))) |v| storage.test_fsync_count = std.fmt.parseInt(u32, v, 10) catch null;
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_RECORD_OPEN_ERRNO"))) |v| test_record_open_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_PREFIX_ERRNO"))) |v| storage.test_prefix_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_LOGS_ERRNO"))) |v| storage.test_logs_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_REDACT_ERRNO"))) |v| storage.test_redact_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_WORKSPACE_ERRNO"))) |v| storage.test_workspace_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_WRITE_ERRNO"))) |v| storage.test_write_errno = storage.testErrno(v);
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_GROUP_GRACE_MS"))) |v| test_group_grace_ms = std.fmt.parseInt(i64, v, 10) catch 0;
    }
    // A single program name, then eb's own arguments: an eb-stack target.
    if (extend.engaged(c.env)) {
        const raw = argv_all[1..];
        const forwarded = a.alloc([]const u8, raw.len) catch oom();
        for (raw, 0..) |arg, n| forwarded[n] = arg;
        return cmdExtend(c, loadSettings(c, .{}), forwarded);
    }

    var args: []const [:0]const u8 = argv_all[1..];
    var command: Command = .build;
    // The helpers a build calls on this program itself; they are not part of its interface.
    var hidden: enum { none, mask_run, mask_preflight } = .none;
    if (args.len > 0) {
        const first: []const u8 = args[0];
        if (std.mem.eql(u8, first, "__mask-run") or std.mem.eql(u8, first, "__mask-preflight")) {
            hidden = if (first[7] == 'r') .mask_run else .mask_preflight;
            args = args[1..];
        }
    }
    if (args.len > 0 and hidden == .none) {
        const first: []const u8 = args[0];
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            return if (emit(usage_text)) 0 else 1;
        }
        if (std.mem.eql(u8, first, "--version")) {
            return if (emit(comptime cli.versionLine(tool, version, build_options.commit))) 0 else 1;
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
    var doctor_profiling = false;
    var doctor_cpu_target: ?[]const u8 = null;
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
        if (hidden == .mask_run and std.mem.eql(u8, x, "--")) {
            for (args[i + 1 ..]) |arg| rest.append(a, arg) catch oom();
            break;
        }
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
            return if (emit(usage_text)) 0 else 1;
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
        } else if (std.mem.eql(u8, x, "--workstation")) {
            g.workstation = true;
        } else if (std.mem.eql(u8, x, "--env") and command == .build and rest.items.len == 0) {
            command = .env;
        } else if (std.mem.eql(u8, x, "--explain") and command == .build and rest.items.len == 0) {
            g.explain = true;
        } else if ((std.mem.eql(u8, x, "--variant") or joined(x, "--variant") != null) and command == .build and rest.items.len == 0) {
            const v = if (joined(x, "--variant")) |j| j else value(args, &i, "--variant");
            if (variantBlock(v) == null) die("--variant takes perf or debug", .{});
            g.variant = v;
        } else if ((std.mem.eql(u8, x, "--cpu-target") or joined(x, "--cpu-target") != null) and command == .build and rest.items.len == 0) {
            g.cpu_target = if (joined(x, "--cpu-target")) |j| j else value(args, &i, "--cpu-target");
        } else if ((std.mem.eql(u8, x, "--mask") or joined(x, "--mask") != null) and command == .build and rest.items.len == 0) {
            const v = if (joined(x, "--mask")) |j| j else value(args, &i, "--mask");
            g.mask = std.meta.stringToEnum(cpumask.Mode, v) orelse die("--mask takes auto, cpuid, kvm or tcg", .{});
        } else if (std.mem.eql(u8, x, "--no-audit") and command == .build and rest.items.len == 0) {
            g.no_audit = true;
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
            .leave => die("leave takes no arguments; got '{s}'", .{x}),
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
                } else if (std.mem.eql(u8, x, "--profiling")) {
                    doctor_profiling = true;
                } else if (std.mem.eql(u8, x, "--cpu-target")) {
                    doctor_cpu_target = value(args, &i, "--cpu-target");
                } else if (joined(x, "--cpu-target")) |v| {
                    doctor_cpu_target = v;
                } else if (std.mem.eql(u8, x, "--workspace")) {
                    if (doctor_workspace != null) die("doctor takes one --workspace", .{});
                    doctor_workspace = value(args, &i, "--workspace");
                } else if (joined(x, "--workspace")) |v| {
                    if (doctor_workspace != null) die("doctor takes one --workspace", .{});
                    doctor_workspace = v;
                } else die("doctor takes --json, --strict, --workspace, --cvmfs, --cvmfs-parallel, --mpi, --profiling and --cpu-target; got '{s}'", .{x});
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
                    if (!validListFilter(x)) die("'{s}' is not a module name", .{x});
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
                } else if (std.mem.eql(u8, x, "--pure")) {
                    g.pure = true;
                } else if (std.mem.eql(u8, x, "--replace")) {
                    g.replace = true;
                } else if (std.mem.eql(u8, x, "--lock")) {
                    g.lock = true;
                } else if (std.mem.eql(u8, x, "--locked")) {
                    g.locked = true;
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
    // Explicit install variables select the mode; without one, configuration
    // selects the same user prefix or project as env.
    if (command == .eb) {
        const s = loadSettings(c, g);
        return if (g.explain) explainExtend(c, s, rest.items) else cmdExtend(c, s, rest.items);
    }
    if (command == .leave) return cmdLeave(c);
    if (hidden == .mask_preflight) return cmdMaskPreflight(c, rest.items);
    if (hidden == .mask_run) return cmdMaskRun(c, g, rest.items);
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
            break :blk cmdClean(c, s, g, clean, g.json_out);
        },
        .build => cmdBuild(c, s, g, rest.items),
        .uninstall => cmdUninstall(c, s, rest.items, uninstall),
        .restore => cmdRestore(c, s, rest.items, uninstall.dry_run),
        .list => blk: {
            if (list_missing and g.json_out) die("list takes --missing or --json, not both", .{});
            break :blk cmdList(c, s, rest.items, g.json_out, list_missing);
        },
        .doctor => cmdDoctor(c, s, g, .{ .strict = doctor_strict, .cvmfs = doctor_cvmfs, .parallel = doctor_parallel, .mpi = doctor_mpi, .profiling = doctor_profiling, .cpu_target = doctor_cpu_target, .workspace = doctor_workspace }),
        .submit => cmdSubmit(c, s, g, rest.items, submit),
        .eb, .leave, .profiles, .site, .@"rpath-wrappers", .check, .@"lmod-cache", .modulerc, .overlay => unreachable,
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = buildScript(arena.allocator(), &install_vars);
    try std.testing.expect(std.mem.indexOf(u8, script, "OMPI_MCA") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "FI_PROVIDER") == null);
}

const extend_source_var = "EBLOCAL_EB_SOURCEPATH";
const extend_toolchains_var = "EBLOCAL_EB_SITE_TOOLCHAINS";

const ExtendEnv = struct {
    env: std.process.Environ.Map,
    exports: []const [2][]const u8,

    fn deinit(self: *ExtendEnv) void {
        self.env.deinit();
    }
};

/// Add the configuration that `env` would select to an `eb` launch, without
/// replacing choices the caller already exported.
fn extendEnvironment(c: Ctx, s: config.Settings) ExtendEnv {
    var env = c.env.clone(c.a) catch oom();
    var exports: std.ArrayList([2][]const u8) = .empty;
    const selected = extend.select(&env) catch return .{ .env = env, .exports = &.{} };
    const selected_name = extend.variable(selected.mode);
    if (env.get(selected_name) == null) {
        const install = configuredInstall(place(c, s));
        env.put(install.variable(), install.prefix) catch oom();
        exports.append(c.a, .{ install.variable(), install.prefix }) catch oom();
    }
    for (s.eessi.items) |v| if (env.get(v.name) == null) {
        env.put(v.name, v.value) catch oom();
        exports.append(c.a, .{ v.name, v.value }) catch oom();
    };
    if (s.site_toolchains.value.len > 0) {
        const json = config.toolchainsJson(c.a, s.site_toolchains.value) catch oom();
        env.put(extend_toolchains_var, json) catch oom();
        exports.append(c.a, .{ extend_toolchains_var, json }) catch oom();
    }

    if (env.get("EASYBUILD_SOURCEPATH") == null) {
        const install_root = env.get("EESSI_USER_INSTALL") orelse env.get("EESSI_PROJECT_INSTALL");
        if (install_root) |root| {
            if (root.len > 0) {
                const prefix = storage.canonical(c.a, root, c.cwd) catch oom();
                const sources = std.fs.path.join(c.a, &.{ prefix, ".eb-local", "sources" }) catch oom();
                env.put(extend_source_var, sources) catch oom();
                exports.append(c.a, .{ extend_source_var, sources }) catch oom();
            }
        }
    }
    return .{ .env = env, .exports = exports.items };
}

fn cmdExtend(c: Ctx, s: config.Settings, args: []const []const u8) u8 {
    const eb_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
    var ext = extendEnvironment(c, s);
    defer ext.deinit();
    const sel = extend.select(&ext.env) catch |err| switch (err) {
        error.TooMany => {
            cli.err("{s}", .{extend.tooMany(c.a, &ext.env) catch oom()});
            return 3;
        },
    };
    extend.apply(&ext.env);
    for (shell_startup) |name| _ = ext.env.swapRemove(name);
    const argv = extend.commandLine(c.a, sel, eb_args) catch oom();
    return stop(runAttached(c.a, argv, envpOf(c.a, &ext.env)));
}

/// What eb-local eb would run: the configured environment exports and the
/// launcher's own script after a `set --` line with the arguments it would
/// get, so the text runs as the launcher does. Nothing runs and nothing is
/// created.
fn explainExtend(c: Ctx, s: config.Settings, args: []const []const u8) u8 {
    const a = c.a;
    const eb_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
    var ext = extendEnvironment(c, s);
    defer ext.deinit();
    const sel = extend.select(&ext.env) catch |err| switch (err) {
        error.TooMany => {
            cli.err("{s}", .{extend.tooMany(a, &ext.env) catch oom()});
            return 3;
        },
    };
    const argv = extend.commandLine(a, sel, eb_args) catch oom();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "# eb-local --explain eb: the script eb-local eb runs, with its arguments. Nothing was run.\n") catch oom();
    const name = extend.variable(sel.mode);
    const val = ext.env.get(name).?;
    out.print(a, "# {s}={s} selects a {s} install; the process umask is {s}.\n", .{ name, qSingleLine(a, val), @tagName(sel.mode), sel.umask }) catch oom();
    if (ext.exports.len > 0) {
        out.appendSlice(a, "# The script gets these environment variables:\n") catch oom();
        for (ext.exports) |kv| out.print(a, "export {s}={s}\n", .{ kv[0], q(a, kv[1]) }) catch oom();
    }
    out.appendSlice(a, "# It runs in a clean bash (no profile, no rc file):\n#  ") catch oom();
    for (argv[0..4]) |x| out.print(a, " {s}", .{x}) catch oom();
    out.appendSlice(a, " \"$SCRIPT\"") catch oom();
    for (argv[5..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.appendSlice(a, "\n# where SCRIPT is everything after the next line.\nset --") catch oom();
    for (argv[6..]) |x| out.print(a, " {s}", .{qSingleLine(a, x)}) catch oom();
    out.print(a, "\n{s}\n", .{extend.script}) catch oom();
    return if (emit(out.items)) 0 else 1;
}

test "extendEnvironment always populates the selected install variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No install variable in caller env -> configured user prefix is added.
    {
        var map: std.process.Environ.Map = .init(a);
        try map.put("HOME", "/home/alice");
        const c: Ctx = .{ .a = a, .io = std.testing.io, .env = &map, .envp = envpOf(a, &map), .cwd = "/" };
        var s: config.Settings = .{};
        s.prefix = .{ .value = "/srv/user-prefix", .from = "test" };
        var ext = extendEnvironment(c, s);
        defer ext.deinit();
        const sel = try extend.select(&ext.env);
        try std.testing.expectEqual(extend.Mode.user, sel.mode);
        try std.testing.expectEqualStrings("/srv/user-prefix", ext.env.get(extend.variable(sel.mode)).?);
        try std.testing.expectEqual(@as(usize, 2), ext.exports.len);
        try std.testing.expectEqualStrings("EESSI_USER_INSTALL", ext.exports[0][0]);
        try std.testing.expectEqualStrings("/srv/user-prefix", ext.exports[0][1]);
        try std.testing.expectEqualStrings(extend_source_var, ext.exports[1][0]);
        try std.testing.expectEqualStrings("/srv/user-prefix/.eb-local/sources", ext.exports[1][1]);
    }

    // Configured project -> EESSI_PROJECT_INSTALL is added.
    {
        var cwd_buf: [sys.path_max]u8 = undefined;
        const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
        const proj = try std.fmt.allocPrint(a, "{s}/.zig-cache/extend-env-project-{d}", .{ cwd, linux.getpid() });
        try common.atomic.makedirs(proj);
        defer storage.removeTree(a, proj) catch {};
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = try sys.z(&zb, proj);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmodat(linux.AT.FDCWD, zp.ptr, 0o2770)));

        var map: std.process.Environ.Map = .init(a);
        try map.put("HOME", "/home/alice");
        const c: Ctx = .{ .a = a, .io = std.testing.io, .env = &map, .envp = envpOf(a, &map), .cwd = cwd };
        var s: config.Settings = .{};
        s.project = .{ .value = proj, .from = "test" };
        var ext = extendEnvironment(c, s);
        defer ext.deinit();
        const sel = try extend.select(&ext.env);
        try std.testing.expectEqual(extend.Mode.project, sel.mode);
        try std.testing.expectEqualStrings(proj, ext.env.get(extend.variable(sel.mode)).?);
        try std.testing.expectEqual(@as(usize, 2), ext.exports.len);
        try std.testing.expectEqualStrings("EESSI_PROJECT_INSTALL", ext.exports[0][0]);
        try std.testing.expectEqualStrings(proj, ext.exports[0][1]);
        try std.testing.expectEqualStrings(extend_source_var, ext.exports[1][0]);
    }

    // Explicit install variable (even empty) -> preserved as the selected variable without re-exporting.
    {
        var map: std.process.Environ.Map = .init(a);
        try map.put("HOME", "/home/alice");
        try map.put("EESSI_SITE_INSTALL", "");
        const c: Ctx = .{ .a = a, .io = std.testing.io, .env = &map, .envp = envpOf(a, &map), .cwd = "/" };
        const s: config.Settings = .{};
        var ext = extendEnvironment(c, s);
        defer ext.deinit();
        const sel = try extend.select(&ext.env);
        try std.testing.expectEqual(extend.Mode.site, sel.mode);
        try std.testing.expectEqualStrings("", ext.env.get(extend.variable(sel.mode)).?);
        try std.testing.expectEqual(@as(usize, 0), ext.exports.len);
    }
}

test "a build has the process umask eb-local eb has for the same install" {
    for ([_]Place{ .{ .prefix = "/x", .project = false }, .{ .prefix = "/x", .project = true } }) |p| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        const install = configuredInstall(p);
        try env.put(install.variable(), install.prefix);
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
        const ran = guard.run(a, &.{ "/bin/sh", "-c", cmd }, no_env) catch return error.TestUnexpectedResult;
        switch (ran) {
            .signal => |got| try std.testing.expectEqual(sig, got),
            .exit, .unreaped => return error.TestUnexpectedResult,
        }
        try std.testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, marker, false));
    }
}

test "settleGroup wakes on SIGCHLD without leaking descriptors" {
    const fds_before = try testSelfFdCount();
    var prev_subreaper: c_int = 0;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.prctl(@backingInt(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&prev_subreaper), 0, 0, 0)),
    );
    if (prev_subreaper == 0) {
        try std.testing.expectEqual(
            linux.E.SUCCESS,
            linux.errno(linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0)),
        );
    }
    defer if (prev_subreaper == 0) {
        _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 0, 0, 0, 0);
    };

    var sync_fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&sync_fds, .{ .CLOEXEC = true })));
    var gate_fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&gate_fds, .{ .CLOEXEC = true })));
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        const grand: isize = @bitCast(linux.fork());
        if (grand == 0) {
            sys.close(sync_fds[0]);
            sys.close(sync_fds[1]);
            sys.close(gate_fds[1]);
            var pfd = [1]linux.pollfd{.{ .fd = gate_fds[0], .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, 2000);
            sys.close(gate_fds[0]);
            linux.exit_group(0);
        }
        sys.close(gate_fds[0]);
        sys.close(gate_fds[1]);
        sys.close(sync_fds[0]);
        _ = linux.write(sync_fds[1], "1", 1);
        sys.close(sync_fds[1]);
        linux.exit_group(15);
    }
    _ = linux.setpgid(@intCast(pid), @intCast(pid));
    sys.close(gate_fds[0]);
    sys.close(sync_fds[1]);
    var one: [1]u8 = undefined;
    _ = linux.read(sync_fds[0], &one, 1);
    sys.close(sync_fds[0]);

    var raw: i32 = 0;
    while (linux.errno(linux.wait4(@intCast(pid), &raw, 0, null)) == .INTR) {}

    var entered_fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&entered_fds, .{ .CLOEXEC = true })));
    settle_entered_fd = entered_fds[1];
    defer settle_entered_fd = -1;

    const ReleaseCtx = struct {
        entered_r: i32,
        gate_w: sys.fd_t,
        fn run(ctx: @This()) void {
            var pfd = [1]linux.pollfd{.{ .fd = ctx.entered_r, .events = linux.POLL.IN, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, 2000);
            if (linux.errno(prc) == .SUCCESS and pfd[0].revents & linux.POLL.IN != 0) {
                var byte: [1]u8 = undefined;
                _ = linux.read(ctx.entered_r, &byte, 1);
            }
            sys.close(ctx.entered_r);
            sys.close(ctx.gate_w);
        }
    };
    const releaser = try std.Thread.spawn(.{}, ReleaseCtx.run, .{ReleaseCtx{
        .entered_r = entered_fds[0],
        .gate_w = gate_fds[1],
    }});

    const t0 = monotonicMs();
    try std.testing.expectEqual(GroupEnd.drained, settleGroup(@intCast(pid)));
    const elapsed = monotonicMs() - t0;
    releaser.join();
    sys.close(entered_fds[1]);
    try std.testing.expect(!proc.groupAlive(@intCast(pid)));
    try std.testing.expect(elapsed < 2000);
    try std.testing.expectEqual(fds_before, try testSelfFdCount());
}

test "settleGroup waits while wait4 reports a child the scan missed" {
    if (comptime !build_options.test_ops) return;

    var entered: [2]i32 = undefined;
    var wake: [2]i32 = undefined;
    var done: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&entered, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&wake, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&done, .{ .CLOEXEC = true })));
    defer {
        sys.close(entered[0]);
        sys.close(entered[1]);
        sys.close(wake[0]);
        sys.close(wake[1]);
        sys.close(done[0]);
        sys.close(done[1]);
    }

    var phase = std.atomic.Value(u8).init(0);
    var probe = SettleProbe{
        .phase = &phase,
        .entered = entered[1],
        .wake = wake[0],
    };
    settle_probe = &probe;
    defer settle_probe = null;

    const Runner = struct {
        done_fd: i32,
        fn run(ctx: @This()) void {
            const end = settleGroup(2147483646);
            _ = linux.write(ctx.done_fd, if (end == .drained) "d" else "x", 1);
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{Runner{ .done_fd = done[1] }});
    defer {
        // A failed assertion must still release the wait, or join blocks.
        phase.store(1, .release);
        _ = linux.write(wake[1], "w", 1);
        thread.join();
    }

    var pfds = [2]linux.pollfd{
        .{ .fd = entered[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = done[0], .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        const rc = linux.poll(&pfds, 2, -1);
        if (linux.errno(rc) == .INTR) continue;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        break;
    }
    const entered_ready = pfds[0].revents & linux.POLL.IN != 0;
    const done_ready = pfds[1].revents & linux.POLL.IN != 0;
    try std.testing.expect(entered_ready);
    try std.testing.expect(!done_ready);

    phase.store(1, .release);
    _ = linux.write(wake[1], "w", 1);
    var byte: [1]u8 = undefined;
    while (true) {
        const n = linux.read(done[0], &byte, 1);
        if (linux.errno(n) == .INTR) continue;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(n));
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(@as(u8, 'd'), byte[0]);
        break;
    }
}

fn waitErrno(e: linux.E) usize {
    return @bitCast(-@as(isize, @backingInt(e)));
}

test "only ECHILD means a process group has no child" {
    switch (readWait(waitErrno(.CHILD))) {
        .reap => |r| try std.testing.expect(r == .empty),
        .retry => return error.TestUnexpectedResult,
    }
    switch (readWait(waitErrno(.INTR))) {
        .retry => {},
        .reap => return error.TestUnexpectedResult,
    }
    switch (readWait(waitErrno(.IO))) {
        .reap => |r| switch (r) {
            .unknown => |err| try std.testing.expectEqual(linux.E.IO, err),
            else => return error.TestUnexpectedResult,
        },
        .retry => return error.TestUnexpectedResult,
    }
    switch (readWait(0)) {
        .reap => |r| try std.testing.expect(r == .live),
        .retry => return error.TestUnexpectedResult,
    }
    switch (readWait(42)) {
        .retry => {},
        .reap => return error.TestUnexpectedResult,
    }
}

const ScriptedEnd = struct {
    done_fd: i32,
    end: *std.atomic.Value(u8),
    fn run(ctx: @This()) void {
        const got = settleGroup(2147483646);
        ctx.end.store(if (got == .drained) 0 else 1, .release);
        _ = linux.write(ctx.done_fd, "d", 1);
    }
};

fn readReady(fd: i32, timeout_ms: i32) !usize {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const rc = linux.poll(&pfd, 1, timeout_ms);
        if (linux.errno(rc) == .INTR) continue;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        return rc;
    }
}

test "settleGroup keeps killing until the scripted reap is empty" {
    if (comptime !build_options.test_ops) return;

    var entered: [2]i32 = undefined;
    var wake: [2]i32 = undefined;
    var done: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&entered, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&wake, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&done, .{ .CLOEXEC = true })));
    defer {
        sys.close(entered[0]);
        sys.close(entered[1]);
        sys.close(wake[0]);
        sys.close(wake[1]);
        sys.close(done[0]);
        sys.close(done[1]);
    }

    // Post-kill wait4 stays live twice, then ECHILD. The first live result
    // blocks in the probe so the test can see that settleGroup has not
    // returned and has not stopped signalling.
    const script = [_]ProbeStep{ .live, .live, .empty };
    var phase = std.atomic.Value(u8).init(0);
    var end = std.atomic.Value(u8).init(255);
    var probe = SettleProbe{
        .phase = &phase,
        .entered = entered[1],
        .wake = wake[0],
        .hold = false,
        .force_kill = true,
        .script = &script,
        .barrier_at = 1,
    };
    settle_probe = &probe;
    defer settle_probe = null;
    const thread = try std.Thread.spawn(.{}, ScriptedEnd.run, .{ScriptedEnd{ .done_fd = done[1], .end = &end }});
    defer {
        probe.release.store(1, .release);
        _ = linux.write(wake[1], "w", 1);
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 1), try readReady(entered[0], 5000));
    try std.testing.expectEqual(@as(usize, 0), try readReady(done[0], 0));
    try std.testing.expectEqual(@as(u32, 1), probe.kills.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), probe.script_i.load(.acquire));

    probe.release.store(1, .release);
    _ = linux.write(wake[1], "w", 1);
    try std.testing.expectEqual(@as(usize, 1), try readReady(done[0], 5000));
    try std.testing.expectEqual(@as(u8, 0), end.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), probe.kills.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), probe.script_i.load(.acquire));
}

test "settleGroup signals a member forked after SIGKILL" {
    if (comptime !build_options.test_ops) return;

    var entered: [2]i32 = undefined;
    var wake: [2]i32 = undefined;
    var done: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&entered, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&wake, .{ .CLOEXEC = true })));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&done, .{ .CLOEXEC = true })));
    defer {
        sys.close(entered[0]);
        sys.close(entered[1]);
        sys.close(wake[0]);
        sys.close(wake[1]);
        sys.close(done[0]);
        sys.close(done[1]);
    }

    // The script would go live, then empty. At the barrier the test arms a
    // late fork, which turns that empty into one more live result. The group
    // must be signalled again after that result and only then reach ECHILD.
    const script = [_]ProbeStep{ .live, .empty };
    var phase = std.atomic.Value(u8).init(0);
    var end = std.atomic.Value(u8).init(255);
    var probe = SettleProbe{
        .phase = &phase,
        .entered = entered[1],
        .wake = wake[0],
        .hold = false,
        .force_kill = true,
        .script = &script,
        .barrier_at = 1,
    };
    settle_probe = &probe;
    defer settle_probe = null;
    const thread = try std.Thread.spawn(.{}, ScriptedEnd.run, .{ScriptedEnd{ .done_fd = done[1], .end = &end }});
    defer {
        probe.release.store(1, .release);
        _ = linux.write(wake[1], "w", 1);
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 1), try readReady(entered[0], 5000));
    try std.testing.expectEqual(@as(usize, 0), try readReady(done[0], 0));
    const kills_before = probe.kills.load(.acquire);
    try std.testing.expectEqual(@as(u32, 1), kills_before);
    probe.late.store(1, .release);

    probe.release.store(1, .release);
    _ = linux.write(wake[1], "w", 1);
    try std.testing.expectEqual(@as(usize, 1), try readReady(done[0], 5000));
    try std.testing.expectEqual(@as(u8, 0), end.load(.acquire));
    try std.testing.expectEqual(@as(u8, 2), probe.late.load(.acquire));
    const at_fork = probe.kills_at_fork.load(.acquire);
    const kills = probe.kills.load(.acquire);
    try std.testing.expect(at_fork > kills_before);
    try std.testing.expect(kills > at_fork);
    try std.testing.expectEqual(@as(u32, 3), kills);
}

test "settleGroup retries an unexpected reap error until ECHILD" {
    if (comptime !build_options.test_ops) return;

    const script = [_]ProbeStep{ .unknown, .unknown, .empty };
    var phase = std.atomic.Value(u8).init(0);
    var probe = SettleProbe{
        .phase = &phase,
        .entered = -1,
        .wake = -1,
        .hold = false,
        .force_kill = true,
        .script = &script,
    };
    settle_probe = &probe;
    defer settle_probe = null;

    try std.testing.expectEqual(GroupEnd.drained, settleGroup(2147483646));
    try std.testing.expectEqual(@as(u32, 3), probe.kills.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), probe.script_i.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), probe.reported.load(.acquire));
}

test "settleGroup returns at the kill deadline while a member stays unreaped" {
    if (comptime !build_options.test_ops) return;

    // phase stays 0, so wait4 keeps reporting a live member. SIGKILL
    // does not clear that answer. The call must return timed_out at the
    // deadline, which is not a drained group, and must not block in wait4.
    var phase = std.atomic.Value(u8).init(0);
    var probe = SettleProbe{
        .phase = &phase,
        .entered = -1,
        .wake = -1,
        .hold = false,
    };
    settle_probe = &probe;
    defer settle_probe = null;

    const fds_before = try testSelfFdCount();
    const t0 = monotonicMs();
    const end = settleGroup(2147483646);
    const elapsed = monotonicMs() - t0;

    const lower = group_settle_grace_ms + group_kill_reap_ms;
    try std.testing.expectEqual(GroupEnd.timed_out, end);
    try std.testing.expectEqual(@as(u32, 1), probe.timeouts.load(.acquire));
    try std.testing.expect(elapsed + 30 >= lower);
    try std.testing.expect(elapsed < lower + 2000);
    try std.testing.expectEqual(fds_before, try testSelfFdCount());
}

test "settleGroup bounds an EINTR storm and a reaped-pid storm" {
    if (comptime !build_options.test_ops) return;

    // Each step repeats. The injected clock stands still during a pass
    // and jumps forward in `pauseUntil`, so a pass runs to the cap and
    // the deadline is what ends the call.
    const steps = [_]ProbeStep{ .eintr, .reaped };
    for (steps) |step| {
        var clock = std.atomic.Value(i64).init(0);
        const script = [_]ProbeStep{step};
        var phase = std.atomic.Value(u8).init(0);
        var probe = SettleProbe{
            .phase = &phase,
            .entered = -1,
            .wake = -1,
            .hold = false,
            .grace_ms = 30,
            .kill_ms = 30,
            .script = &script,
            .script_from_start = true,
            .clock = &clock,
        };
        settle_probe = &probe;
        defer settle_probe = null;

        const end = settleGroup(2147483646);

        try std.testing.expectEqual(GroupEnd.timed_out, end);
        const waits = probe.wait_calls.load(.acquire);
        const passes = probe.passes.load(.acquire);
        const most = probe.max_pass_waits.load(.acquire);
        try std.testing.expect(passes > 1);
        try std.testing.expect(most <= reap_pass_cap);
        try std.testing.expectEqual(reap_pass_cap, most);
        // The deadline is already due on the last pass, so that pass
        // stops after one `EINTR` or reaped pid instead of filling the cap.
        try std.testing.expectEqual(@as(u32, 1), probe.last_pass_waits.load(.acquire));
        try std.testing.expect(waits <= passes * reap_pass_cap);
        try std.testing.expect(waits > reap_pass_cap);
        try std.testing.expect(clock.load(.acquire) >= probe.grace_ms + probe.kill_ms);
        try std.testing.expectEqual(@as(u32, 1), probe.timeouts.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), probe.reported.load(.acquire));
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

test "siteConfigCandidates checks checkout root when running from zig-out/bin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const installed = siteConfigCandidates(a, "/opt/eb-local/bin");
    try std.testing.expectEqual(@as(usize, 4), installed.len);
    try std.testing.expectEqualStrings("/opt/eb-local/bin/config.toml", installed[0]);
    try std.testing.expectEqualStrings("/etc/eb-local/config.toml", installed[1]);
    try std.testing.expectEqualStrings("/opt/eb-local/bin/eb-local.conf", installed[2]);
    try std.testing.expectEqualStrings("/etc/eb-local.conf", installed[3]);

    const checkout = siteConfigCandidates(a, "/work/eb-local/zig-out/bin");
    try std.testing.expectEqual(@as(usize, 6), checkout.len);
    try std.testing.expectEqualStrings("/work/eb-local/zig-out/bin/config.toml", checkout[0]);
    try std.testing.expectEqualStrings("/work/eb-local/config.toml", checkout[1]);
    try std.testing.expectEqualStrings("/etc/eb-local/config.toml", checkout[2]);
    try std.testing.expectEqualStrings("/work/eb-local/zig-out/bin/eb-local.conf", checkout[3]);
    try std.testing.expectEqualStrings("/work/eb-local/eb-local.conf", checkout[4]);
    try std.testing.expectEqualStrings("/etc/eb-local.conf", checkout[5]);
}
