//! `eb-local __vm-run`: run a command under a virtual CPU that presents an
//! EESSI CPU target. An internal helper, absent from `--help`.
//!
//! `--mode kvm` boots the host kernel under QEMU with KVM, a named CPU model
//! per target and `enforce`; the guest's root is the host's, read-only over
//! virtiofs, with /cvmfs and the build directories shared. `--mode tcg` runs
//! the command in qemu user mode with `QEMU_CPU` set, for a target of another
//! architecture. Before the command starts, the guest checks that EESSI
//! archdetect, archspec, `gcc -march=native` (or `-mcpu=native`), the CPU
//! vendor and /dev/fd all name the target, and the helper refuses when one
//! does not.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;
const proc = common.proc;
const Allocator = std.mem.Allocator;

const guest_init = @embedFile("vm/guest-init.sh");
const verify_script = @embedFile("vm/verify.sh");
const tcg_ns_script = @embedFile("vm/tcg-ns.sh");

/// Refused before anything started: usage, an unknown target, a target this
/// mode cannot present, or a missing tool.
pub const status_refused: u8 = 2;
/// The VM or emulator failed, so the command did not report a status.
pub const status_failed: u8 = 125;
/// The guest checked the CPU view and it does not name the target; the
/// command did not run.
pub const status_unverified: u8 = 126;

/// The kind of virtual CPU: KVM for the host's architecture, qemu user mode for the other.
pub const Mode = enum { kvm, tcg };
/// The CPU architectures a target can have.
pub const Arch = enum { x86_64, aarch64 };

/// The architecture this binary runs on.
pub const host_arch: Arch = switch (builtin.cpu.arch) {
    .aarch64 => .aarch64,
    else => .x86_64,
};

/// The mitigation bits a host that is not affected sets, so that a guest
/// kernel does not take the Safe-RET path on every kernel entry, and the
/// TSC-deadline timer.
const amd_bits = "srso-user-kernel-no=on,sbpb=on,ibpb-brtype=on,tsa-sq-no=on,tsa-l1-no=on,tsc-deadline=on";

/// An EESSI CPU target, what each detector must call it, and the QEMU CPU
/// that presents it.
pub const Target = struct {
    /// The EESSI software subdirectory.
    name: []const u8,
    arch: Arch,
    /// `vendor_id` on x86_64, `CPU implementer` on aarch64.
    vendor: []const u8,
    /// archspec's name for the CPU.
    archspec: []const u8,
    /// What `gcc -march=native` (x86_64) or `-mcpu=native` (aarch64) names,
    /// as space-separated alternatives.
    gcc: []const u8,
    /// The `-cpu` value, without `enforce`, under KVM.
    kvm: ?[]const u8 = null,
    kvm_refusal: []const u8 = "",
    /// The `-cpu` value in qemu user mode.
    tcg: ?[]const u8 = null,
    tcg_refusal: []const u8 = "",
};

const no_zen5 = "a Zen 5 guest needs a Zen 5 host: archspec reads zen5 only with cppc, tsc_adjust and flush_l1d, none of which survive into a KVM guest";
const no_avx512 = "TCG has no AVX-512, so the guest would be a zen3 or a haswell to every tool";
const no_arm_kvm = "KVM on Arm offers the host CPU only; use --mode tcg from an x86_64 host";
const no_x86_kvm = "an x86_64 target needs an x86_64 host under KVM, or --mode tcg from an aarch64 host";

/// Every target `__vm-run` knows.
pub const targets = [_]Target{
    .{ .name = "x86_64/amd/zen2", .arch = .x86_64, .vendor = "AuthenticAMD", .archspec = "zen2", .gcc = "znver2", .kvm = "EPYC-Rome," ++ amd_bits, .tcg = "EPYC-Rome" },
    .{ .name = "x86_64/amd/zen3", .arch = .x86_64, .vendor = "AuthenticAMD", .archspec = "zen3", .gcc = "znver3", .kvm = "EPYC-Milan,pcid=off," ++ amd_bits, .tcg = "EPYC-Milan" },
    .{ .name = "x86_64/amd/zen4", .arch = .x86_64, .vendor = "AuthenticAMD", .archspec = "zen4", .gcc = "znver4", .kvm = "EPYC-Genoa,flush-l1d=on,la57=off,pcid=off," ++ amd_bits, .tcg_refusal = no_avx512 },
    .{ .name = "x86_64/amd/zen5", .arch = .x86_64, .vendor = "AuthenticAMD", .archspec = "zen5", .gcc = "znver5", .kvm_refusal = no_zen5, .tcg_refusal = no_avx512 },
    .{ .name = "x86_64/intel/haswell", .arch = .x86_64, .vendor = "GenuineIntel", .archspec = "haswell", .gcc = "haswell", .kvm = "Haswell-noTSX-IBRS,vendor=GenuineIntel,pcid=off", .tcg = "Haswell-noTSX-IBRS,vendor=GenuineIntel" },
    .{ .name = "x86_64/intel/skylake_avx512", .arch = .x86_64, .vendor = "GenuineIntel", .archspec = "skylake_avx512", .gcc = "skylake-avx512", .kvm = "Skylake-Server-v5,vendor=GenuineIntel,pcid=off,clflushopt=on", .tcg_refusal = no_avx512 },
    .{ .name = "x86_64/intel/cascadelake", .arch = .x86_64, .vendor = "GenuineIntel", .archspec = "cascadelake", .gcc = "cascadelake", .kvm = "Cascadelake-Server-v5,vendor=GenuineIntel,pcid=off,ibrs-all=off", .tcg_refusal = no_avx512 },
    .{ .name = "x86_64/intel/icelake", .arch = .x86_64, .vendor = "GenuineIntel", .archspec = "icelake", .gcc = "icelake-server", .kvm = "Icelake-Server-v7,vendor=GenuineIntel,hle=off,rtm=off,ibrs-all=off,la57=off,pcid=off,taa-no=off", .tcg_refusal = no_avx512 },
    .{ .name = "x86_64/intel/sapphirerapids", .arch = .x86_64, .vendor = "GenuineIntel", .archspec = "sapphirerapids", .gcc = "sapphirerapids", .kvm = "SapphireRapids-v4,vendor=GenuineIntel,pcid=off,la57=off", .tcg_refusal = no_avx512 },
    .{ .name = "aarch64/neoverse_n1", .arch = .aarch64, .vendor = "0x41", .archspec = "neoverse_n1", .gcc = "neoverse-n1", .kvm_refusal = no_arm_kvm, .tcg = "neoverse-n1" },
    .{ .name = "aarch64/neoverse_v1", .arch = .aarch64, .vendor = "0x41", .archspec = "neoverse_v1", .gcc = "neoverse-v1", .kvm_refusal = no_arm_kvm, .tcg = "neoverse-v1" },
    .{ .name = "aarch64/a64fx", .arch = .aarch64, .vendor = "0x46", .archspec = "a64fx", .gcc = "a64fx", .kvm_refusal = no_arm_kvm, .tcg = "a64fx" },
};

/// The target named `name`, an EESSI software subdirectory.
pub fn find(name: []const u8) ?*const Target {
    for (&targets) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// What a mode does for a target on a host: the QEMU CPU, or the reason it
/// cannot.
pub const Plan = union(enum) {
    /// The `-cpu` value, `enforce` included.
    kvm: []const u8,
    /// The `QEMU_CPU` value.
    tcg: []const u8,
    refused: []const u8,
};

/// What `mode` does for target `t` on a `host`: the QEMU CPU, or why it cannot.
pub fn plan(a: Allocator, t: *const Target, mode: Mode, host: Arch) Allocator.Error!Plan {
    switch (mode) {
        .kvm => {
            if (t.arch != host) return .{ .refused = if (t.arch == .aarch64) no_arm_kvm else no_x86_kvm };
            const model = t.kvm orelse return .{ .refused = t.kvm_refusal };
            return .{ .kvm = try std.fmt.allocPrint(a, "{s},enforce", .{model}) };
        },
        .tcg => {
            if (t.arch == host) return .{ .refused = "--mode tcg is for a target of another architecture; use --mode kvm" };
            const model = t.tcg orelse return .{ .refused = t.tcg_refusal };
            return .{ .tcg = model };
        },
    }
}

/// A command line after `__vm-run`.
pub const Request = struct {
    mode: Mode,
    target: []const u8,
    memory_mib: u32 = 8192,
    cpus: ?u32 = null,
    share: []const []const u8 = &.{},
    share_ro: []const []const u8 = &.{},
    allow_archspec_mismatch: bool = false,
    command: []const []const u8,
};

/// The result of `parseArgs`.
pub const Parsed = union(enum) {
    ok: Request,
    /// The message for stderr.
    bad: []const u8,
};

fn optValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const x = args[i.*];
    if (std.mem.eql(u8, x, name)) {
        if (i.* + 1 >= args.len) return null;
        i.* += 1;
        return args[i.*];
    }
    if (x.len > name.len and std.mem.startsWith(u8, x, name) and x[name.len] == '=') return x[name.len + 1 ..];
    return null;
}

fn isOpt(x: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, x, name) or (x.len > name.len and std.mem.startsWith(u8, x, name) and x[name.len] == '=');
}

/// Parse `--mode kvm|tcg --cpu-target TARGET [--memory MiB] [--cpus N]
/// [--share DIR] [--share-ro DIR] [--allow-archspec-mismatch] -- COMMAND...`.
pub fn parseArgs(a: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    var mode: ?Mode = null;
    var target: ?[]const u8 = null;
    var req: Request = .{ .mode = .kvm, .target = "", .command = &.{} };
    var share: std.ArrayList([]const u8) = .empty;
    var share_ro: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, "--")) {
            i += 1;
            break;
        }
        if (isOpt(x, "--mode")) {
            const v = optValue(args, &i, "--mode") orelse return .{ .bad = "--mode needs kvm or tcg" };
            mode = std.meta.stringToEnum(Mode, v) orelse return .{ .bad = "--mode takes kvm or tcg" };
        } else if (isOpt(x, "--cpu-target")) {
            target = optValue(args, &i, "--cpu-target") orelse return .{ .bad = "--cpu-target needs a target" };
        } else if (isOpt(x, "--memory")) {
            const v = optValue(args, &i, "--memory") orelse return .{ .bad = "--memory needs a size in MiB" };
            req.memory_mib = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "--memory takes a number of MiB" };
            if (req.memory_mib < 256) return .{ .bad = "--memory takes at least 256 MiB" };
        } else if (isOpt(x, "--cpus")) {
            const v = optValue(args, &i, "--cpus") orelse return .{ .bad = "--cpus needs a number" };
            const n = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "--cpus takes a number" };
            if (n == 0) return .{ .bad = "--cpus takes at least 1" };
            req.cpus = n;
        } else if (isOpt(x, "--share")) {
            try share.append(a, optValue(args, &i, "--share") orelse return .{ .bad = "--share needs a directory" });
        } else if (isOpt(x, "--share-ro")) {
            try share_ro.append(a, optValue(args, &i, "--share-ro") orelse return .{ .bad = "--share-ro needs a directory" });
        } else if (std.mem.eql(u8, x, "--allow-archspec-mismatch")) {
            req.allow_archspec_mismatch = true;
        } else {
            return .{ .bad = try std.fmt.allocPrint(a, "__vm-run does not know '{s}'", .{x}) };
        }
    }
    req.mode = mode orelse return .{ .bad = "__vm-run needs --mode kvm|tcg" };
    req.target = target orelse return .{ .bad = "__vm-run needs --cpu-target TARGET" };
    if (i >= args.len) return .{ .bad = "__vm-run needs -- COMMAND [ARG...]" };
    req.command = args[i..];
    req.share = try share.toOwnedSlice(a);
    req.share_ro = try share_ro.toOwnedSlice(a);
    return .{ .ok = req };
}

/// One virtiofs share: a daemon serving `host`, a device tagged `tag`.
pub const Share = struct {
    tag: []const u8,
    host: []const u8,
    /// Where the guest mounts it; empty for the root and the job directory,
    /// which the kernel and the init mount.
    guest: []const u8 = "",
    readonly: bool = true,
    cache: []const u8 = "always",
};

/// What the guest's kernel command line and QEMU need.
pub const KvmConfig = struct {
    qemu: []const u8,
    cpu: []const u8,
    cpus: u32,
    memory_mib: u32,
    kernel: []const u8,
    rundir: []const u8,
    shares: []const Share,
};

/// The vhost-user socket of share `tag` in the job directory.
pub fn socketPath(a: Allocator, rundir: []const u8, tag: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.sock", .{ rundir, tag });
}

/// The kernel command line: the host root over virtiofs, read-only, and the
/// init in the job directory.
pub fn kernelCmdline(a: Allocator, rundir: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "console=ttyS0 rootfstype=virtiofs root=hostroot ro init={s}/init panic=-1 quiet", .{rundir});
}

/// The QEMU command line. The CPU is the named model with `enforce`; no
/// argument names the host CPU.
pub fn qemuArgv(a: Allocator, cfg: KvmConfig) Allocator.Error![]const []const u8 {
    var v: std.ArrayList([]const u8) = .empty;
    const fixed = [_][]const u8{ "-accel", "kvm", "-machine", "q35", "-display", "none", "-nodefaults", "-no-user-config", "-monitor", "none", "-no-reboot", "-cpu" };
    for (fixed) |x| try v.append(a, x);
    try v.append(a, cfg.cpu);
    try v.append(a, "-smp");
    try v.append(a, try std.fmt.allocPrint(a, "{d}", .{cfg.cpus}));
    try v.append(a, "-m");
    try v.append(a, try std.fmt.allocPrint(a, "{d}M", .{cfg.memory_mib}));
    try v.append(a, "-object");
    try v.append(a, try std.fmt.allocPrint(a, "memory-backend-memfd,id=mem,size={d}M,share=on", .{cfg.memory_mib}));
    try v.append(a, "-numa");
    try v.append(a, "node,memdev=mem");
    for (cfg.shares, 0..) |s, n| {
        try v.append(a, "-chardev");
        try v.append(a, try std.fmt.allocPrint(a, "socket,id=fs{d},path={s}", .{ n, try socketPath(a, cfg.rundir, s.tag) }));
        try v.append(a, "-device");
        try v.append(a, try std.fmt.allocPrint(a, "vhost-user-fs-pci,chardev=fs{d},tag={s}", .{ n, s.tag }));
    }
    // ttyS0 is the console log; ttyS1 and ttyS2 carry the command's stdout and stderr.
    try v.append(a, "-serial");
    try v.append(a, try std.fmt.allocPrint(a, "file:{s}/console.log", .{cfg.rundir}));
    try v.append(a, "-chardev");
    try v.append(a, "file,id=so,path=/proc/self/fd/1,append=on");
    try v.append(a, "-serial");
    try v.append(a, "chardev:so");
    try v.append(a, "-chardev");
    try v.append(a, "file,id=se,path=/proc/self/fd/2,append=on");
    try v.append(a, "-serial");
    try v.append(a, "chardev:se");
    try v.append(a, "-kernel");
    try v.append(a, cfg.kernel);
    try v.append(a, "-append");
    try v.append(a, try kernelCmdline(a, cfg.rundir));
    return v.toOwnedSlice(a);
}

/// The virtiofsd command line for share `s`: no sandbox, read-only when the share is.
pub fn virtiofsdArgv(a: Allocator, virtiofsd: []const u8, rundir: []const u8, s: Share) Allocator.Error![]const []const u8 {
    var v: std.ArrayList([]const u8) = .empty;
    try v.append(a, virtiofsd);
    try v.append(a, try std.fmt.allocPrint(a, "--socket-path={s}", .{try socketPath(a, rundir, s.tag)}));
    try v.append(a, try std.fmt.allocPrint(a, "--shared-dir={s}", .{s.host}));
    try v.append(a, "--sandbox=none");
    if (s.readonly) try v.append(a, "--readonly");
    try v.append(a, try std.fmt.allocPrint(a, "--cache={s}", .{s.cache}));
    try v.append(a, "--log-level=error");
    return v.toOwnedSlice(a);
}

/// The guest init's `mounts` file: one line per mount, parent paths first.
pub fn mountsFile(a: Allocator, shares: []const Share, cvmfs_root: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (cvmfs_root) try out.appendSlice(a, "tmpfs cvmfs /cvmfs\n");
    for (shares) |s| {
        if (s.guest.len == 0) continue;
        try out.print(a, "virtiofs {s} {s} {s}\n", .{ s.tag, s.guest, if (s.readonly) "ro" else "rw" });
    }
    return out.toOwnedSlice(a);
}

/// Drop each path that lies inside another one in the list, and repeats;
/// sorted shortest first so that a parent is mounted before its children
/// would be.
pub fn dedupePaths(a: Allocator, paths: []const []const u8) Allocator.Error![]const []const u8 {
    const sorted = try a.dupe([]const u8, paths);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            if (x.len != y.len) return x.len < y.len;
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var keep: std.ArrayList([]const u8) = .empty;
    outer: for (sorted) |p| {
        for (keep.items) |k| {
            if (std.mem.eql(u8, k, p)) continue :outer;
            if (std.mem.startsWith(u8, p, k) and p.len > k.len and (p[k.len] == '/' or std.mem.eql(u8, k, "/"))) continue :outer;
        }
        try keep.append(a, p);
    }
    return keep.toOwnedSlice(a);
}

/// Environment variables the command receives in the guest.
pub fn envForwarded(name: []const u8) bool {
    const exact = [_][]const u8{
        "PATH",       "HOME",          "USER",      "LOGNAME",        "LANG",            "TERM",          "TZ",                "TMPDIR",
        "MODULEPATH", "LOADEDMODULES", "_LMFILES_", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "SOURCE_DATE_EPOCH", "WORKING_DIR",
    };
    for (exact) |e| if (std.mem.eql(u8, name, e)) return true;
    const prefixes = [_][]const u8{ "LC_", "LMOD", "EASYBUILD_", "EESSI_", "EB_", "SLURM_" };
    if (std.mem.startsWith(u8, name, "EB_LOCAL_VM_")) return false;
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// The variables whose values name directories the command writes.
pub const writable_vars = [_][]const u8{
    "HOME",                  "TMPDIR",                "XDG_CACHE_HOME",       "WORKING_DIR",              "EASYBUILD_PREFIX",
    "EASYBUILD_BUILDPATH",   "EASYBUILD_INSTALLPATH", "EASYBUILD_SOURCEPATH", "EASYBUILD_REPOSITORYPATH", "EESSI_USER_INSTALL",
    "EESSI_PROJECT_INSTALL", "EESSI_SITE_INSTALL",
};

/// `s` in single quotes for a POSIX shell.
pub fn shellQuote(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(a, "'\\''");
        } else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}

/// The values the job script exports for the verification and the command.
pub const Job = struct {
    /// The job directory as the command sees it.
    dir: []const u8,
    cwd: []const u8,
    t: *const Target,
    eessi_version: []const u8,
    allow_archspec_mismatch: bool,
    gcc_bin: []const u8 = "",
    /// Name and value of every variable the command receives.
    env: []const [2][]const u8,
    command: []const []const u8,
};

/// The script the guest runs as the caller: the environment, the working directory, the CPU check, then the command.
pub fn jobScript(a: Allocator, j: Job) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "#!/bin/bash\n");
    for (j.env) |kv| try out.print(a, "export {s}={s}\n", .{ kv[0], try shellQuote(a, kv[1]) });
    const arch = @tagName(j.t.arch);
    const pairs = [_][2][]const u8{
        .{ "EBVM_DIR", j.dir },
        .{ "EBVM_ARCH", arch },
        .{ "EBVM_TARGET", j.t.name },
        .{ "EBVM_VENDOR", j.t.vendor },
        .{ "EBVM_ARCHSPEC", j.t.archspec },
        .{ "EBVM_GCC", j.t.gcc },
        .{ "EBVM_EESSI_VERSION", j.eessi_version },
        .{ "EBVM_ALLOW_ARCHSPEC", if (j.allow_archspec_mismatch) "1" else "0" },
        .{ "EBVM_GCC_BIN", j.gcc_bin },
    };
    for (pairs) |kv| try out.print(a, "export {s}={s}\n", .{ kv[0], try shellQuote(a, kv[1]) });
    try out.print(a, "cd {s} || {{ echo 'eb-local: vm-run: cannot enter the working directory' >&2; exit 127; }}\n", .{try shellQuote(a, j.cwd)});
    try out.appendSlice(a, "bash \"$EBVM_DIR/verify.sh\" || exit 126\n");
    try out.appendSlice(a, "exec");
    for (j.command) |x| try out.print(a, " {s}", .{try shellQuote(a, x)});
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

/// What the guest left in the job directory.
pub const Outcome = struct {
    /// The `refused` file, when the verification refused.
    refused: ?[]const u8 = null,
    /// The `status` file, when the guest init wrote one.
    status: ?[]const u8 = null,
};

/// The helper's exit status for what the guest reported. A refusal is 126
/// whatever else exists; a command's own status passes through; no report is
/// a VM failure.
pub fn exitStatus(o: Outcome) u8 {
    if (o.refused != null) return status_unverified;
    const text = std.mem.trim(u8, o.status orelse return status_failed, " \t\r\n");
    const n = std.fmt.parseInt(u16, text, 10) catch return status_failed;
    if (n > 255) return status_failed;
    return @intCast(n);
}

/// The status of a process the helper waited for: its exit code, or 128 plus
/// the signal.
pub fn termStatus(raw: u32) u8 {
    if (linux.W.IFEXITED(raw)) return linux.W.EXITSTATUS(raw);
    if (linux.W.IFSIGNALED(raw)) return @intCast(128 + @as(u32, @backingInt(linux.W.TERMSIG(raw))));
    return status_failed;
}

fn err(comptime fmt: []const u8, args: anytype) void {
    cli.err("eb-local: vm-run: " ++ fmt ++ "\n", args);
}

fn readSmall(a: Allocator, path: []const u8) ?[]u8 {
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch return null;
    defer sys.close(fd);
    return fsx.readAll(a, fd, 1 << 20) catch null;
}

/// Bytes of a failed guest's `console.log` printed after its path.
const console_tail_len: usize = 2000;

/// The last `console_tail_len` bytes of a regular file, or the whole file
/// when it is shorter. The read starts at the end, so a console log past
/// the one mebibyte `readSmall` accepts still yields its tail. Null when
/// the file cannot be read.
fn consoleTail(a: Allocator, path: []const u8) ?[]u8 {
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch return null;
    defer sys.close(fd);
    const st = fsx.fstat(fd) catch return null;
    if (!st.isReg()) return null;
    const take: usize = if (st.size > console_tail_len) console_tail_len else @intCast(st.size);
    const offset: linux.off_t = if (st.size > console_tail_len) -@as(linux.off_t, @intCast(console_tail_len)) else 0;
    const whence: u32 = if (st.size > console_tail_len) linux.SEEK.END else linux.SEEK.SET;
    _ = sys.call(linux.lseek, .{ fd, offset, whence }) catch return null;
    const buf = a.alloc(u8, take) catch return null;
    var got: usize = 0;
    while (got < take) {
        const n = sys.read(fd, buf[got..]) catch {
            a.free(buf);
            return null;
        };
        if (n == 0) break;
        got += n;
    }
    if (got == take) return buf;
    const exact = a.dupe(u8, buf[0..got]) catch {
        a.free(buf);
        return null;
    };
    a.free(buf);
    return exact;
}

fn writeFile(path: []const u8, bytes: []const u8, mode: linux.mode_t) !void {
    const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    defer sys.close(fd);
    try sys.writeAll(fd, bytes);
    try sys.fchmod(fd, mode);
}

fn isDir(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, true) catch return false;
    return st.isDir();
}

fn executable(a: Allocator, path: []const u8) bool {
    const z = a.dupeSentinel(u8, path, 0) catch return false;
    return linux.errno(linux.access(z.ptr, 1)) == .SUCCESS;
}

/// An executable `name`: in `EB_LOCAL_QEMU_DIR` when that is set and holds
/// it, then in PATH, then in the usual places a distribution puts it.
fn locate(a: Allocator, env: *const std.process.Environ.Map, name: []const u8, extra: []const []const u8) ?[]const u8 {
    if (env.get("EB_LOCAL_QEMU_DIR")) |d| if (d.len > 0) {
        const p = std.fs.path.join(a, &.{ d, name }) catch return null;
        if (executable(a, p)) return p;
    };
    if (env.get("PATH")) |path| {
        if (proc.which(a, name, path) catch null) |p| return p;
    }
    for (extra) |d| {
        const p = std.fs.path.join(a, &.{ d, name }) catch return null;
        if (executable(a, p)) return p;
    }
    return null;
}

fn cpuCount() u32 {
    var set: linux.cpu_set_t = undefined;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set)) != .SUCCESS) return 1;
    return @max(linux.CPU_COUNT(set), 1);
}

fn kernelPath(a: Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("EB_LOCAL_VM_KERNEL")) |k| if (k.len > 0) {
        const fd = sys.openat(fsx.cwd, k, .{}, 0) catch return null;
        sys.close(fd);
        return k;
    };
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return null;
    const rel = std.mem.sliceTo(&uts.release, 0);
    const cands = [_][]const u8{
        std.fmt.allocPrint(a, "/lib/modules/{s}/vmlinuz", .{rel}) catch return null,
        std.fmt.allocPrint(a, "/boot/vmlinuz-{s}", .{rel}) catch return null,
        "/boot/vmlinuz",
    };
    for (cands) |p| {
        const fd = sys.openat(fsx.cwd, p, .{}, 0) catch continue;
        sys.close(fd);
        return p;
    }
    return null;
}

const Spawned = struct { pid: linux.pid_t };

fn spawn(a: Allocator, argv: []const []const u8, envp: proc.Envp) !Spawned {
    const zargv = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |x, i| zargv[i] = (try a.dupeSentinel(u8, x, 0)).ptr;
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.SpawnFailed,
    }
    if (rc == 0) {
        // A child does not outlive the helper.
        _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @intCast(@backingInt(linux.SIG.KILL)), 0, 0, 0);
        _ = linux.execve(zargv[0].?, zargv.ptr, envp);
        cli.err("eb-local: vm-run: cannot run {s}\n", .{argv[0]});
        linux.exit_group(127);
    }
    return .{ .pid = @intCast(rc) };
}

fn waitFor(pid: linux.pid_t) u32 {
    var raw: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &raw, 0, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return @bitCast(raw),
            .INTR => continue,
            else => return 0xff00,
        }
    }
}

fn waitForSocket(path: []const u8) bool {
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        if (fsx.statAt(fsx.cwd, path, true)) |_| return true else |_| {}
        var ts: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    return false;
}

/// The directories to mount writable and read-only: the working directory,
/// the caller's `--share`s and the directories its environment names, each
/// only when it exists and no wider share holds it.
fn writableShares(a: Allocator, env: *const std.process.Environ.Map, cwd: []const u8, extra: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(a, cwd);
    for (extra) |p| try list.append(a, p);
    for (writable_vars) |name| {
        const v = env.get(name) orelse continue;
        var it = std.mem.splitScalar(u8, v, ':');
        while (it.next()) |p| try list.append(a, p);
    }
    var ok: std.ArrayList([]const u8) = .empty;
    for (list.items) |p| {
        if (p.len == 0 or p[0] != '/' or std.mem.eql(u8, p, "/")) continue;
        if (std.mem.indexOfAny(u8, p, " \t\n\\\"'") != null) continue;
        if (isDir(p)) try ok.append(a, try fsx.absPath(a, p));
    }
    return dedupePaths(a, ok.items);
}

/// Run `request` and return the helper's exit status.
pub fn run(a: Allocator, env: *const std.process.Environ.Map, cwd: []const u8, args: []const []const u8) u8 {
    const parsed = parseArgs(a, args) catch {
        err("out of memory", .{});
        return status_failed;
    };
    const req = switch (parsed) {
        .ok => |r| r,
        .bad => |m| {
            err("{s}", .{m});
            return status_refused;
        },
    };
    const t = find(req.target) orelse {
        var names: std.ArrayList(u8) = .empty;
        for (&targets) |*x| names.print(a, " {s}", .{x.name}) catch {};
        err("unknown target '{s}'; known:{s}", .{ req.target, names.items });
        return status_refused;
    };
    const chosen = plan(a, t, req.mode, host_arch) catch return status_failed;
    switch (chosen) {
        .refused => |why| {
            err("{s} under --mode {s}: {s}", .{ t.name, @tagName(req.mode), why });
            return status_refused;
        },
        .kvm => |cpu| return runKvm(a, env, cwd, req, t, cpu),
        .tcg => |cpu| return runTcg(a, env, cwd, req, t, cpu),
    }
}

fn eessiVersion(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("EESSI_VERSION")) |v| if (v.len > 0) return v;
    return "2026.06";
}

/// A directory for the job: `EB_LOCAL_VM_DIR`, TMPDIR, /var/tmp or /tmp.
/// Under KVM it must be on the root file system, which the guest boots from.
fn makeRundir(a: Allocator, env: *const std.process.Environ.Map, need_root_fs: bool) ?[]const u8 {
    const root_dev = (fsx.statAt(fsx.cwd, "/", true) catch return null).dev;
    var cands: std.ArrayList([]const u8) = .empty;
    if (env.get("EB_LOCAL_VM_DIR")) |d| if (d.len > 0) cands.append(a, d) catch return null;
    if (env.get("TMPDIR")) |d| if (d.len > 0) cands.append(a, d) catch return null;
    cands.append(a, "/var/tmp") catch return null;
    cands.append(a, "/tmp") catch return null;
    for (cands.items) |d| {
        const st = fsx.statAt(fsx.cwd, d, true) catch continue;
        if (!st.isDir()) continue;
        if (need_root_fs and st.dev != root_dev) continue;
        if (std.mem.indexOfAny(u8, d, " \t\n") != null) continue;
        return fsx.mkdtemp(a, d, "eb-local-vm.") catch continue;
    }
    return null;
}

fn forwardedEnv(a: Allocator, env: *const std.process.Environ.Map, path_override: ?[]const u8) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = env.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (!envForwarded(name) or !common.env.validName(name)) continue;
        var value = kv.value_ptr.*;
        if (path_override) |p| if (std.mem.eql(u8, name, "PATH")) {
            value = p;
        };
        try out.append(a, .{ name, value });
    }
    return out.toOwnedSlice(a);
}

fn envBlock(a: Allocator, env: *const std.process.Environ.Map, extra: []const [2][]const u8) !proc.Envp {
    var b: common.env.Builder = .init(a);
    var it = env.iterator();
    while (it.next()) |kv| try b.set(kv.key_ptr.*, kv.value_ptr.*);
    for (extra) |kv| try b.set(kv[0], kv[1]);
    return b.envp();
}

fn runKvm(a: Allocator, env: *const std.process.Environ.Map, cwd: []const u8, req: Request, t: *const Target, cpu: []const u8) u8 {
    const qemu_name = if (host_arch == .x86_64) "qemu-system-x86_64" else "qemu-system-aarch64";
    const qemu = locate(a, env, qemu_name, &.{ "/usr/bin", "/usr/local/bin" }) orelse {
        err("{s} not found: put it on PATH or set EB_LOCAL_QEMU_DIR to its directory", .{qemu_name});
        return status_refused;
    };
    const virtiofsd = if (env.get("EB_LOCAL_VIRTIOFSD")) |v| (if (v.len > 0) v else null) else null;
    const vfsd = virtiofsd orelse locate(a, env, "virtiofsd", &.{ "/usr/lib/virtiofsd", "/usr/libexec", "/usr/bin" }) orelse {
        err("virtiofsd not found: put it on PATH, in EB_LOCAL_QEMU_DIR, or set EB_LOCAL_VIRTIOFSD to its path", .{});
        return status_refused;
    };
    if (!executable(a, vfsd)) {
        err("virtiofsd is not executable at {s}", .{vfsd});
        return status_refused;
    }
    const kernel = kernelPath(a, env) orelse {
        err("no readable host kernel image: set EB_LOCAL_VM_KERNEL (it needs virtiofs and virtio-pci built in)", .{});
        return status_refused;
    };
    const kvm_z = a.dupeSentinel(u8, "/dev/kvm", 0) catch return status_failed;
    if (linux.errno(linux.access(kvm_z.ptr, 6)) != .SUCCESS) {
        err("/dev/kvm is not readable and writable here; --mode kvm needs KVM", .{});
        return status_refused;
    }
    const rundir = makeRundir(a, env, true) orelse {
        err("no directory for the job on the root file system: set EB_LOCAL_VM_DIR", .{});
        return status_refused;
    };

    // The shares: the host root, the job directory, EESSI, and what the build writes.
    var shares: std.ArrayList(Share) = .empty;
    const build = fail: {
        shares.append(a, .{ .tag = "hostroot", .host = "/" }) catch break :fail false;
        shares.append(a, .{ .tag = "job", .host = rundir, .readonly = false, .cache = "never" }) catch break :fail false;
        const repos = if (env.get("EB_LOCAL_VM_CVMFS_REPOS")) |v| (if (v.len > 0) v else "software.eessi.io") else "software.eessi.io";
        var rit = std.mem.tokenizeAny(u8, repos, ": ,");
        var n: usize = 0;
        while (rit.next()) |repo| : (n += 1) {
            shares.append(a, .{
                .tag = std.fmt.allocPrint(a, "cvmfs{d}", .{n}) catch break :fail false,
                .host = std.fmt.allocPrint(a, "/cvmfs/{s}", .{repo}) catch break :fail false,
                .guest = std.fmt.allocPrint(a, "/cvmfs/{s}", .{repo}) catch break :fail false,
            }) catch break :fail false;
        }
        const extra_rw = writableShares(a, env, cwd, req.share) catch break :fail false;
        for (extra_rw, 0..) |p, i| shares.append(a, .{
            .tag = std.fmt.allocPrint(a, "rw{d}", .{i}) catch break :fail false,
            .host = p,
            .guest = p,
            .readonly = false,
            .cache = "auto",
        }) catch break :fail false;
        for (req.share_ro, 0..) |p, i| shares.append(a, .{
            .tag = std.fmt.allocPrint(a, "ro{d}", .{i}) catch break :fail false,
            .host = fsx.absPath(a, p) catch break :fail false,
            .guest = fsx.absPath(a, p) catch break :fail false,
        }) catch break :fail false;
        break :fail true;
    };
    if (!build) return status_failed;

    const mount_text = mountsFile(a, shares.items, true) catch return status_failed;
    const uid = linux.getuid();
    const gid = linux.getgid();
    var groups_buf: [256]linux.gid_t = undefined;
    const ng = linux.getgroups(groups_buf.len, &groups_buf);
    var ids: std.ArrayList(u8) = .empty;
    ids.print(a, "EBVM_UID={d}\nEBVM_GID={d}\nEBVM_GROUPS=", .{ uid, gid }) catch return status_failed;
    if (linux.errno(ng) == .SUCCESS) {
        for (groups_buf[0..ng], 0..) |g, i| ids.print(a, "{s}{d}", .{ if (i > 0) "," else "", g }) catch return status_failed;
    }
    ids.append(a, '\n') catch return status_failed;

    const fwd = forwardedEnv(a, env, null) catch return status_failed;
    const gcc_bin = if (env.get("EB_LOCAL_VM_GCC")) |v| v else "";
    const job = jobScript(a, .{
        .dir = "/run/ebvm",
        .cwd = cwd,
        .t = t,
        .eessi_version = eessiVersion(env),
        .allow_archspec_mismatch = req.allow_archspec_mismatch,
        .gcc_bin = gcc_bin,
        .env = fwd,
        .command = req.command,
    }) catch return status_failed;

    const files = [_]struct { name: []const u8, bytes: []const u8, mode: linux.mode_t }{
        .{ .name = "init", .bytes = guest_init, .mode = 0o755 },
        .{ .name = "verify.sh", .bytes = verify_script, .mode = 0o755 },
        .{ .name = "job.sh", .bytes = job, .mode = 0o700 },
        .{ .name = "mounts", .bytes = mount_text, .mode = 0o600 },
        .{ .name = "ids", .bytes = ids.items, .mode = 0o600 },
    };
    for (files) |f| {
        const p = std.fs.path.join(a, &.{ rundir, f.name }) catch return status_failed;
        writeFile(p, f.bytes, f.mode) catch |e| {
            err("cannot write {s}: {s}", .{ p, sys.describe(sys.asError(e) orelse error.Unexpected) });
            return status_failed;
        };
    }

    const base_env = envBlock(a, env, &.{}) catch return status_failed;
    var daemons: std.ArrayList(linux.pid_t) = .empty;
    defer {
        for (daemons.items) |pid| {
            _ = linux.kill(pid, .TERM);
            _ = waitFor(pid);
        }
    }
    for (shares.items) |s| {
        const argv = virtiofsdArgv(a, vfsd, rundir, s) catch return status_failed;
        const sp = spawn(a, argv, base_env) catch {
            err("cannot start virtiofsd", .{});
            return status_failed;
        };
        daemons.append(a, sp.pid) catch return status_failed;
    }
    for (shares.items) |s| {
        const sock = socketPath(a, rundir, s.tag) catch return status_failed;
        if (!waitForSocket(sock)) {
            err("virtiofsd did not create {s}; sharing {s} failed", .{ sock, s.host });
            return status_failed;
        }
    }

    const qargs = qemuArgv(a, .{
        .qemu = qemu,
        .cpu = cpu,
        .cpus = req.cpus orelse cpuCount(),
        .memory_mib = req.memory_mib,
        .kernel = kernel,
        .rundir = rundir,
        .shares = shares.items,
    }) catch return status_failed;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, qemu) catch return status_failed;
    argv.appendSlice(a, qargs) catch return status_failed;
    const q = spawn(a, argv.items, base_env) catch {
        err("cannot start QEMU", .{});
        return status_failed;
    };
    const raw = waitFor(q.pid);

    const outcome: Outcome = .{
        .refused = readSmall(a, std.fs.path.join(a, &.{ rundir, "refused" }) catch return status_failed),
        .status = readSmall(a, std.fs.path.join(a, &.{ rundir, "status" }) catch return status_failed),
    };
    const code = exitStatus(outcome);
    if (code == status_failed) {
        err("the guest reported no status (QEMU {s}); console log: {s}/console.log", .{ if (termStatus(raw) == 0) "exited 0" else "failed", rundir });
        const log_path = std.fs.path.join(a, &.{ rundir, "console.log" }) catch return status_failed;
        if (consoleTail(a, log_path)) |tail| cli.err("{s}\n", .{tail});
        if (qemuRefusedModel(raw)) err("QEMU refused the CPU model {s}: this host lacks a feature it needs (enforce is on, and the helper never falls back to the host CPU)", .{cpu});
        return status_failed;
    }
    if (std.mem.eql(u8, env.get("EB_LOCAL_VM_KEEP") orelse "", "1")) {
        err("job directory kept: {s}", .{rundir});
    } else fsx.deleteTree(a, fsx.cwd, rundir) catch {};
    return code;
}

fn qemuRefusedModel(raw: u32) bool {
    return linux.W.IFEXITED(raw) and linux.W.EXITSTATUS(raw) != 0;
}

fn runTcg(a: Allocator, env: *const std.process.Environ.Map, cwd: []const u8, req: Request, t: *const Target, cpu: []const u8) u8 {
    const arch = @tagName(t.arch);
    const qemu_name = std.fmt.allocPrint(a, "qemu-{s}", .{arch}) catch return status_failed;
    const qemu = locate(a, env, qemu_name, &.{ "/usr/bin", "/usr/local/bin" }) orelse {
        err("{s} not found: put it on PATH or set EB_LOCAL_QEMU_DIR to its directory", .{qemu_name});
        return status_refused;
    };
    const version = eessiVersion(env);
    const compat = std.fmt.allocPrint(a, "/cvmfs/software.eessi.io/versions/{s}/compat/linux/{s}", .{ version, arch }) catch return status_failed;
    if (!isDir(compat)) {
        err("the EESSI {s} compat layer is not readable at {s}", .{ version, compat });
        return status_refused;
    }
    const rundir = makeRundir(a, env, false) orelse {
        err("no directory for the job: set EB_LOCAL_VM_DIR", .{});
        return status_refused;
    };
    const prefix_path = std.fmt.allocPrint(a, "{s}/bin:{s}/usr/bin:{s}/sbin:{s}/usr/sbin", .{ compat, compat, compat, compat }) catch return status_failed;
    const path = std.fmt.allocPrint(a, "{s}:{s}", .{ prefix_path, env.get("PATH") orelse "/usr/bin:/bin" }) catch return status_failed;
    var fwd: std.ArrayList([2][]const u8) = .empty;
    fwd.appendSlice(a, forwardedEnv(a, env, path) catch return status_failed) catch return status_failed;
    var has_path = false;
    for (fwd.items) |kv| if (std.mem.eql(u8, kv[0], "PATH")) {
        has_path = true;
    };
    if (!has_path) fwd.append(a, .{ "PATH", path }) catch return status_failed;
    fwd.append(a, .{ "QEMU_CPU", cpu }) catch return status_failed;
    const job = jobScript(a, .{
        .dir = rundir,
        .cwd = cwd,
        .t = t,
        .eessi_version = version,
        .allow_archspec_mismatch = req.allow_archspec_mismatch,
        .gcc_bin = env.get("EB_LOCAL_VM_GCC") orelse "",
        .env = fwd.items,
        .command = req.command,
    }) catch return status_failed;
    const files = [_]struct { name: []const u8, bytes: []const u8, mode: linux.mode_t }{
        .{ .name = "verify.sh", .bytes = verify_script, .mode = 0o755 },
        .{ .name = "tcg-ns.sh", .bytes = tcg_ns_script, .mode = 0o755 },
        .{ .name = "job.sh", .bytes = job, .mode = 0o700 },
    };
    for (files) |f| {
        const p = std.fs.path.join(a, &.{ rundir, f.name }) catch return status_failed;
        writeFile(p, f.bytes, f.mode) catch |e| {
            err("cannot write {s}: {s}", .{ p, sys.describe(sys.asError(e) orelse error.Unexpected) });
            return status_failed;
        };
    }
    const job_path = std.fs.path.join(a, &.{ rundir, "job.sh" }) catch return status_failed;
    const ns_path = std.fs.path.join(a, &.{ rundir, "tcg-ns.sh" }) catch return status_failed;
    const bash = locate(a, env, "bash", &.{ "/usr/bin", "/bin" }) orelse {
        err("bash not found", .{});
        return status_refused;
    };

    const registered = std.fmt.allocPrint(a, "/proc/sys/fs/binfmt_misc/qemu-{s}", .{arch}) catch return status_failed;
    const have_binfmt = if (fsx.statAt(fsx.cwd, registered, true)) |_| true else |_| false;
    var argv: std.ArrayList([]const u8) = .empty;
    var extra: std.ArrayList([2][]const u8) = .empty;
    extra.append(a, .{ "QEMU_CPU", cpu }) catch return status_failed;
    if (have_binfmt) {
        argv.appendSlice(a, &.{ bash, job_path }) catch return status_failed;
        extra.append(a, .{ "PATH", path }) catch return status_failed;
    } else {
        const unshare = locate(a, env, "unshare", &.{ "/usr/bin", "/bin" }) orelse {
            err("no binfmt_misc entry for qemu-{s} and no unshare to register one in a user namespace", .{arch});
            return status_refused;
        };
        argv.appendSlice(a, &.{ unshare, "--user", "--map-root-user", "--mount", bash, ns_path }) catch return status_failed;
        const idv = [_][2][]const u8{
            .{ "EBVM_ARCH", arch },
            .{ "EBVM_QEMU_USER", qemu },
            .{ "EBVM_QEMU_CPU", cpu },
            .{ "EBVM_UID", std.fmt.allocPrint(a, "{d}", .{linux.getuid()}) catch return status_failed },
            .{ "EBVM_GID", std.fmt.allocPrint(a, "{d}", .{linux.getgid()}) catch return status_failed },
            .{ "EBVM_JOB", job_path },
            .{ "EBVM_PATH", path },
        };
        extra.appendSlice(a, &idv) catch return status_failed;
    }
    const envp = envBlock(a, env, extra.items) catch return status_failed;
    const child = spawn(a, argv.items, envp) catch {
        err("cannot start the emulation", .{});
        return status_failed;
    };
    const raw = waitFor(child.pid);
    const refused = readSmall(a, std.fs.path.join(a, &.{ rundir, "refused" }) catch return status_failed);
    var code = termStatus(raw);
    if (refused != null) code = status_unverified;
    fsx.deleteTree(a, fsx.cwd, rundir) catch {};
    return code;
}

const testing = std.testing;

fn testTarget(name: []const u8) *const Target {
    return find(name).?;
}

test "an AMD target keeps its model, the corrections and enforce" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zen4 = try plan(a, testTarget("x86_64/amd/zen4"), .kvm, .x86_64);
    try testing.expectEqualStrings("EPYC-Genoa,flush-l1d=on,la57=off,pcid=off,srso-user-kernel-no=on,sbpb=on,ibpb-brtype=on,tsa-sq-no=on,tsa-l1-no=on,tsc-deadline=on,enforce", zen4.kvm);
    const zen3 = try plan(a, testTarget("x86_64/amd/zen3"), .kvm, .x86_64);
    try testing.expectEqualStrings("EPYC-Milan,pcid=off,srso-user-kernel-no=on,sbpb=on,ibpb-brtype=on,tsa-sq-no=on,tsa-l1-no=on,tsc-deadline=on,enforce", zen3.kvm);
    const zen2 = try plan(a, testTarget("x86_64/amd/zen2"), .kvm, .x86_64);
    try testing.expect(std.mem.startsWith(u8, zen2.kvm, "EPYC-Rome,srso-user-kernel-no=on"));
    try testing.expect(std.mem.endsWith(u8, zen2.kvm, ",enforce"));
}

test "an Intel target names the vendor and strips only non-ISA bits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "x86_64/intel/haswell", "x86_64/intel/skylake_avx512", "x86_64/intel/cascadelake", "x86_64/intel/icelake", "x86_64/intel/sapphirerapids" }) |name| {
        const p = try plan(a, testTarget(name), .kvm, .x86_64);
        try testing.expect(std.mem.indexOf(u8, p.kvm, "vendor=GenuineIntel") != null);
        try testing.expect(std.mem.endsWith(u8, p.kvm, ",enforce"));
    }
    const icelake = try plan(a, testTarget("x86_64/intel/icelake"), .kvm, .x86_64);
    try testing.expectEqualStrings("Icelake-Server-v7,vendor=GenuineIntel,hle=off,rtm=off,ibrs-all=off,la57=off,pcid=off,taa-no=off,enforce", icelake.kvm);
    const skylake = try plan(a, testTarget("x86_64/intel/skylake_avx512"), .kvm, .x86_64);
    try testing.expect(std.mem.indexOf(u8, skylake.kvm, "clflushopt=on") != null);
    const spr = try plan(a, testTarget("x86_64/intel/sapphirerapids"), .kvm, .x86_64);
    try testing.expect(std.mem.startsWith(u8, spr.kvm, "SapphireRapids"));
}

test "no target maps to the host CPU" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (&targets) |*t| {
        const p = try plan(a, t, .kvm, t.arch);
        switch (p) {
            .kvm => |cpu| {
                try testing.expect(!std.mem.startsWith(u8, cpu, "host"));
                try testing.expect(std.mem.endsWith(u8, cpu, ",enforce"));
            },
            else => {},
        }
        try testing.expect(t.kvm == null or !std.mem.startsWith(u8, t.kvm.?, "host"));
    }
}

test "aarch64 targets run under emulation with a named model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("neoverse-n1", (try plan(a, testTarget("aarch64/neoverse_n1"), .tcg, .x86_64)).tcg);
    try testing.expectEqualStrings("neoverse-v1", (try plan(a, testTarget("aarch64/neoverse_v1"), .tcg, .x86_64)).tcg);
    try testing.expectEqualStrings("a64fx", (try plan(a, testTarget("aarch64/a64fx"), .tcg, .x86_64)).tcg);
}

test "a mode refuses what it cannot present" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // KVM on Arm offers the host CPU only; the other architecture is emulation.
    try testing.expect((try plan(a, testTarget("aarch64/neoverse_n1"), .kvm, .x86_64)) == .refused);
    try testing.expect((try plan(a, testTarget("aarch64/neoverse_n1"), .kvm, .aarch64)) == .refused);
    try testing.expect((try plan(a, testTarget("x86_64/amd/zen4"), .kvm, .aarch64)) == .refused);
    // TCG has no AVX-512 and the same architecture belongs to KVM.
    try testing.expect((try plan(a, testTarget("x86_64/amd/zen4"), .tcg, .aarch64)) == .refused);
    try testing.expect((try plan(a, testTarget("x86_64/amd/zen3"), .tcg, .x86_64)) == .refused);
    try testing.expectEqualStrings("EPYC-Milan", (try plan(a, testTarget("x86_64/amd/zen3"), .tcg, .aarch64)).tcg);
    // A Zen 5 guest needs a Zen 5 host.
    try testing.expect((try plan(a, testTarget("x86_64/amd/zen5"), .kvm, .x86_64)) == .refused);
}

test "the QEMU command line names the model with enforce, shares and the three serial ports" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shares = [_]Share{
        .{ .tag = "hostroot", .host = "/" },
        .{ .tag = "job", .host = "/var/tmp/j", .readonly = false },
    };
    const argv = try qemuArgv(a, .{
        .qemu = "qemu-system-x86_64",
        .cpu = "EPYC-Genoa,enforce",
        .cpus = 4,
        .memory_mib = 2048,
        .kernel = "/boot/vmlinuz",
        .rundir = "/var/tmp/j",
        .shares = &shares,
    });
    var cpu_at: ?usize = null;
    for (argv, 0..) |x, i| {
        try testing.expect(!std.mem.eql(u8, x, "host"));
        if (std.mem.eql(u8, x, "-cpu")) cpu_at = i;
    }
    try testing.expectEqualStrings("EPYC-Genoa,enforce", argv[cpu_at.? + 1]);
    var serial: usize = 0;
    var vfs: usize = 0;
    for (argv) |x| {
        if (std.mem.eql(u8, x, "-serial")) serial += 1;
        if (std.mem.startsWith(u8, x, "vhost-user-fs-pci,")) vfs += 1;
    }
    try testing.expectEqual(@as(usize, 3), serial);
    try testing.expectEqual(@as(usize, 2), vfs);
    try testing.expect(std.mem.indexOf(u8, argv[argv.len - 1], "root=hostroot ro init=/var/tmp/j/init") != null);
    try testing.expectEqualStrings("kvm", argv[1]);
    try testing.expectEqualStrings("-smp", argv[cpu_at.? + 2]);
    try testing.expectEqualStrings("4", argv[cpu_at.? + 3]);
    try testing.expectEqualStrings("-m", argv[cpu_at.? + 4]);
    try testing.expectEqualStrings("2048M", argv[cpu_at.? + 5]);
}

test "virtiofsd shares the host read-only without a sandbox" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ro = try virtiofsdArgv(a, "/bin/virtiofsd", "/var/tmp/j", .{ .tag = "hostroot", .host = "/" });
    try testing.expectEqualStrings("--socket-path=/var/tmp/j/hostroot.sock", ro[1]);
    try testing.expectEqualStrings("--shared-dir=/", ro[2]);
    try testing.expectEqualStrings("--sandbox=none", ro[3]);
    try testing.expectEqualStrings("--readonly", ro[4]);
    const rw = try virtiofsdArgv(a, "/bin/virtiofsd", "/var/tmp/j", .{ .tag = "rw0", .host = "/home/u", .guest = "/home/u", .readonly = false, .cache = "auto" });
    for (rw) |x| try testing.expect(!std.mem.eql(u8, x, "--readonly"));
    try testing.expectEqualStrings("--cache=auto", rw[4]);
}

test "mounts list the tmpfs under /cvmfs first, then each guest path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shares = [_]Share{
        .{ .tag = "hostroot", .host = "/" },
        .{ .tag = "cvmfs0", .host = "/cvmfs/software.eessi.io", .guest = "/cvmfs/software.eessi.io" },
        .{ .tag = "rw0", .host = "/home/u", .guest = "/home/u", .readonly = false },
    };
    const text = try mountsFile(a, &shares, true);
    try testing.expectEqualStrings("tmpfs cvmfs /cvmfs\nvirtiofs cvmfs0 /cvmfs/software.eessi.io ro\nvirtiofs rw0 /home/u rw\n", text);
}

test "paths inside another share are dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kept = try dedupePaths(a, &.{ "/home/u/work", "/home/u", "/var/lib/builds/x", "/home/u", "/home/uu" });
    try testing.expectEqual(@as(usize, 3), kept.len);
    try testing.expectEqualStrings("/home/u", kept[0]);
    try testing.expectEqualStrings("/home/uu", kept[1]);
    try testing.expectEqualStrings("/var/lib/builds/x", kept[2]);
}

test "arguments: the stable command line and the optional extras" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parseArgs(a, &.{ "--mode", "kvm", "--cpu-target", "x86_64/amd/zen4", "--memory", "4096", "--cpus=2", "--", "eb-local", "--flag", "x" });
    try testing.expectEqual(Mode.kvm, ok.ok.mode);
    try testing.expectEqualStrings("x86_64/amd/zen4", ok.ok.target);
    try testing.expectEqual(@as(u32, 4096), ok.ok.memory_mib);
    try testing.expectEqual(@as(?u32, 2), ok.ok.cpus);
    try testing.expectEqual(@as(usize, 3), ok.ok.command.len);
    try testing.expectEqualStrings("--flag", ok.ok.command[1]);
    const share = try parseArgs(a, &.{ "--mode=tcg", "--cpu-target=aarch64/neoverse_n1", "--share", "/a", "--share-ro=/b", "--allow-archspec-mismatch", "--", "true" });
    try testing.expectEqual(Mode.tcg, share.ok.mode);
    try testing.expectEqualStrings("/a", share.ok.share[0]);
    try testing.expectEqualStrings("/b", share.ok.share_ro[0]);
    try testing.expect(share.ok.allow_archspec_mismatch);
}

test "arguments: each missing or wrong piece is named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { args: []const []const u8, text: []const u8 }{
        .{ .args = &.{ "--cpu-target", "x", "--", "true" }, .text = "--mode" },
        .{ .args = &.{ "--mode", "kvm", "--", "true" }, .text = "--cpu-target" },
        .{ .args = &.{ "--mode", "kvm", "--cpu-target", "x" }, .text = "COMMAND" },
        .{ .args = &.{ "--mode", "kvm", "--cpu-target", "x", "--" }, .text = "COMMAND" },
        .{ .args = &.{ "--mode", "vm", "--cpu-target", "x", "--", "true" }, .text = "kvm or tcg" },
        .{ .args = &.{ "--mode", "kvm", "--cpu-target", "x", "--memory", "lots", "--", "true" }, .text = "MiB" },
        .{ .args = &.{ "--mode", "kvm", "--cpu-target", "x", "--cpus", "0", "--", "true" }, .text = "--cpus" },
        .{ .args = &.{ "--mode", "kvm", "--cpu-target", "x", "--bogus", "--", "true" }, .text = "--bogus" },
    };
    for (cases) |c| {
        const p = try parseArgs(a, c.args);
        try testing.expect(p == .bad);
        try testing.expect(std.mem.indexOf(u8, p.bad, c.text) != null);
    }
}

test "exit status: the command's own, 126 for a refusal, 125 for no report" {
    try testing.expectEqual(@as(u8, 0), exitStatus(.{ .status = "0\n" }));
    try testing.expectEqual(@as(u8, 7), exitStatus(.{ .status = "7\n" }));
    try testing.expectEqual(@as(u8, 137), exitStatus(.{ .status = "137" }));
    try testing.expectEqual(status_unverified, exitStatus(.{ .refused = "archspec reads x86_64_v4", .status = "0" }));
    try testing.expectEqual(status_failed, exitStatus(.{}));
    try testing.expectEqual(status_failed, exitStatus(.{ .status = "banana" }));
    try testing.expectEqual(status_failed, exitStatus(.{ .status = "300" }));
    try testing.expectEqual(@as(u8, 3), termStatus(3 << 8));
    try testing.expectEqual(@as(u8, 137), termStatus(9));
}

test "the job script quotes every word and checks the CPU before the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = try jobScript(a, .{
        .dir = "/run/ebvm",
        .cwd = "/home/u/it's",
        .t = testTarget("x86_64/amd/zen4"),
        .eessi_version = "2025.06",
        .allow_archspec_mismatch = false,
        .env = &.{.{ "FOO", "a b$c" }},
        .command = &.{ "eb", "--robot", "a;b" },
    });
    try testing.expect(std.mem.indexOf(u8, script, "export FOO='a b$c'\n") != null);
    try testing.expect(std.mem.indexOf(u8, script, "export EBVM_VENDOR='AuthenticAMD'\n") != null);
    try testing.expect(std.mem.indexOf(u8, script, "export EBVM_GCC='znver4'\n") != null);
    try testing.expect(std.mem.indexOf(u8, script, "cd '/home/u/it'\\''s'") != null);
    const verify = std.mem.indexOf(u8, script, "verify.sh").?;
    const exec = std.mem.indexOf(u8, script, "exec 'eb' '--robot' 'a;b'\n").?;
    try testing.expect(verify < exec);
}

test "only the named variables reach the guest" {
    try testing.expect(envForwarded("PATH"));
    try testing.expect(envForwarded("EASYBUILD_PREFIX"));
    try testing.expect(envForwarded("EESSI_USER_INSTALL"));
    try testing.expect(envForwarded("LC_ALL"));
    try testing.expect(!envForwarded("SSH_AUTH_SOCK"));
    try testing.expect(!envForwarded("DISPLAY"));
    try testing.expect(!envForwarded("EB_LOCAL_VM_KERNEL"));
}

test "a console log past one mebibyte yields its final bytes" {
    const a = testing.allocator;
    const root = try fsx.mkdtemp(a, "/tmp", "eb-local-vmlog-");
    defer a.free(root);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const path = try std.fs.path.join(a, &.{ root, "console.log" });
    defer a.free(path);
    const marker = "TAIL-MARKER\n";
    const total = (1 << 20) + 80;
    const body = try a.alloc(u8, total);
    defer a.free(body);
    @memset(body, 'x');
    @memcpy(body[0..4], "HEAD");
    @memcpy(body[total - marker.len ..], marker);
    try writeFile(path, body, 0o644);

    const tail = consoleTail(a, path);
    try testing.expect(tail != null);
    const got = tail.?;
    defer a.free(got);
    try testing.expectEqual(console_tail_len, got.len);
    try testing.expect(std.mem.endsWith(u8, got, marker));
    try testing.expect(std.mem.indexOf(u8, got, "HEAD") == null);
}

test "a console log within one mebibyte keeps its final bytes" {
    const a = testing.allocator;
    const root = try fsx.mkdtemp(a, "/tmp", "eb-local-vmlog-");
    defer a.free(root);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const path = try std.fs.path.join(a, &.{ root, "console.log" });
    defer a.free(path);

    try writeFile(path, "short\n", 0o644);
    const whole = consoleTail(a, path).?;
    defer a.free(whole);
    try testing.expectEqualStrings("short\n", whole);

    var mid: [5000]u8 = undefined;
    @memset(&mid, 'm');
    @memcpy(mid[mid.len - 6 ..], "MIDDLE");
    try writeFile(path, &mid, 0o644);
    const tail = consoleTail(a, path).?;
    defer a.free(tail);
    try testing.expectEqual(console_tail_len, tail.len);
    try testing.expect(std.mem.endsWith(u8, tail, "MIDDLE"));
}

test "the guest scripts check every detector and refuse" {
    try testing.expect(std.mem.indexOf(u8, verify_script, "/dev/fd/0") != null);
    try testing.expect(std.mem.indexOf(u8, verify_script, "eessi_archdetect.sh") != null);
    try testing.expect(std.mem.indexOf(u8, verify_script, "archspec.cpu") != null);
    try testing.expect(std.mem.indexOf(u8, verify_script, "-march=native") != null);
    try testing.expect(std.mem.indexOf(u8, verify_script, "-mcpu=native") != null);
    try testing.expect(std.mem.indexOf(u8, verify_script, "vendor_id") != null);
    try testing.expect(std.mem.indexOf(u8, guest_init, "/dev/fd") != null);
}
