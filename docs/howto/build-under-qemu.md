<!-- Generated from docs/orgmode/howto/build-under-qemu.org by docs/export.el; edit that file. -->

# Build under a virtual CPU with QEMU

A build that detects the CPU it runs on gets the host's view, so a Zen 5 node builds for Zen 5 whatever target you want.
`eb-local __vm-run` runs a command inside QEMU with a CPU that presents the target instead, and checks that every detector agrees before the command starts.
It is an internal helper: [the command reference](../reference/cli.md) lists its options and exit statuses, and the builds that mask the CPU view call it.
These steps run it by hand, to see what a target looks like or to debug a masked build.

## Before you start

For `--mode kvm`, a target of the host's architecture:

-   `/dev/kvm`, readable and writable by you.
-   `qemu-system-x86_64` and `virtiofsd` on `PATH`, or in a directory that `EB_LOCAL_QEMU_DIR` names, with `EB_LOCAL_VIRTIOFSD` for a `virtiofsd` elsewhere. On a Nix host the directory is the `bin` of the QEMU store path.
-   A host kernel that has virtiofs, virtio-pci and devtmpfs built in. The helper boots `/lib/modules/$(uname -r)/vmlinuz`, then `/boot/vmlinuz-$(uname -r)`; `EB_LOCAL_VM_KERNEL` names another image.
-   `bash`, `setpriv` and `stty` from util-linux and coreutils on the host: the guest runs the host's own root file system, read-only.
-   A temporary directory on the root file system: `EB_LOCAL_VM_DIR`, `TMPDIR`, `/var/tmp` or `/tmp`, the first that is.
-   EESSI mounted at `/cvmfs/software.eessi.io`.

For `--mode tcg`, a target of the other architecture:

-   `qemu-aarch64` (or `qemu-x86_64` on an aarch64 host), found as above.
-   A kernel that lets you create user and mount namespaces, 6.7 or later, unless the host already has a `qemu-aarch64` entry in `binfmt_misc`. Without the entry, the helper registers the emulator in a namespace of its own, which needs no root.
-   The EESSI compatibility layer of the target's architecture under `/cvmfs/software.eessi.io`.

`EESSI_VERSION` names the EESSI version both modes check; it defaults to `2026.06`.

## Run a command as a Zen 4

```bash
eb-local __vm-run --mode kvm --cpu-target x86_64/amd/zen4 -- \
    bash -c 'gcc -march=native -Q --help=target | grep -- -march='
```

The guest boots in a few seconds, checks the CPU, and prints one line before the command output:

```text
eb-local: vm-run: x86_64/amd/zen4 presented: vendor=AuthenticAMD archdetect=x86_64/amd/zen4 archspec=zen4 gcc=znver4
```

The compiler then names `znver4` on a Zen 5 host.
The command runs in your working directory, as your user and group, and its exit status is the helper's.
Files it creates there belong to you.

The guest mounts these writable: your working directory and the directories `HOME`, `TMPDIR`, `EASYBUILD_PREFIX`, `EASYBUILD_BUILDPATH`, `EASYBUILD_INSTALLPATH`, `EASYBUILD_SOURCEPATH`, `EASYBUILD_REPOSITORYPATH` and the `EESSI_*_INSTALL` variables name.
Everything else on the host root is read-only, and `/tmp` is memory.
`--share DIR` mounts another writable directory; `--share-ro DIR` mounts a read-only one that lies on a file system other than `/`, such as `/nix`.
`--memory` and `--cpus` size the guest.

## Run a command as an Intel Ice Lake

```bash
eb-local __vm-run --mode kvm --cpu-target x86_64/intel/icelake -- grep -m1 vendor_id /proc/cpuinfo
```

The vendor reads `GenuineIntel`; QEMU keeps the host's vendor unless the model sets it, and every detector goes wrong on an Intel model with an AMD vendor.

## Run a command as a Neoverse N1

```bash
eb-local __vm-run --mode tcg --cpu-target aarch64/neoverse_n1 --allow-archspec-mismatch -- \
    bash -c 'uname -m; gcc -mcpu=native -### -c x.c 2>&1 | grep -o -- -mcpu=[^\ ]*'
```

The command runs on the EESSI aarch64 compatibility layer, whose directories come first in `PATH`, in qemu user mode with `QEMU_CPU=neoverse-n1`.
`uname -m` reads `aarch64`, and the compiler names `neoverse-n1`.
No guest kernel boots, and no memory or CPU count applies.

QEMU's user mode writes its own `/proc/cpuinfo` for the program, with the CPU part of the model, which EESSI archdetect and GCC read correctly.
Its feature line lacks `evtstrm`, the one feature archspec 0.2.5 requires for `neoverse_n1` that the line leaves out, so archspec reads `aarch64` and the helper refuses without `--allow-archspec-mismatch`.
An easyblock that keys on archspec then sees a generic Arm CPU while the EESSI subdirectory and the compiler see `neoverse_n1`; pass the option only for a command that does not use archspec's answer.

## What the helper refuses

The guest checks, before the command, that:

1.  `/dev/fd` exists; without it EESSI archdetect fails on its process substitution and EESSI selects the generic target.
2.  The CPU vendor (`vendor_id` or the Arm implementer) names the target's.
3.  EESSI archdetect and the EESSI software subdirectory both name the target.
4.  `gcc -march=native` (`-mcpu=native` on aarch64) names the target's compiler architecture.
5.  archspec, from the EasyBuild module's Python, names the target.

Any other reading exits 126, names the check on stderr, and does not start the command.
The helper also never uses the host CPU: `enforce` makes QEMU refuse a model the host cannot present, and the helper then exits 125 and says so, where a hand-run QEMU would fall back to `-cpu host` and report the host's target.

| Situation | Status | Why |
|---|---|---|
| `x86_64/amd/zen5`, an Arm target under `kvm` | 2 | KVM offers no Zen 5 guest on another CPU, and on Arm only the host CPU. |
| An AVX-512 target under `tcg` | 2 | TCG has no AVX-512, so the guest would be a Zen 3 to every tool. |
| A target of the host's architecture under `tcg` | 2 | `kvm` presents it at native speed. |
| `x86_64/intel/sapphirerapids` on a host without AMX | 125 | `enforce` refuses the model: its instructions are real, and no guest can supply them. |

## What it costs

Wall times on a Ryzen 9 9950X (Zen 5) host under load, from the helper's start to its exit, EESSI 2026.06, 8 vCPUs, 8 GiB:

| Target | Mode | Wall time | What ran |
|---|---|---|---|
| `x86_64/amd/zen4` | kvm | 9 to 15 s | boot, the five checks, `gcc -march=native` |
| `x86_64/intel/icelake` | kvm | 10 to 13 s | the same |
| `x86_64/amd/zen2` | kvm | 11 to 17 s | the same |
| `x86_64/amd/zen3` | kvm | 12 to 13 s | the same |
| `aarch64/neoverse_n1` | tcg | 15 to 21 s | the checks, `uname -m`, a one-line C compile and run under emulation |
| `aarch64/neoverse_v1` | tcg | 18 to 25 s | the same, and the SVE vector length |
| `aarch64/a64fx` | tcg | 19 s | the same |

A guest of an SVE core reports the vector length the core has: 32 bytes (256 bits) for `aarch64/neoverse_v1`, 64 bytes (512 bits) for `aarch64/a64fx`, and none for `aarch64/neoverse_n1`.

Most of the time goes to the checks, which load EESSI, GCC and EasyBuild modules.
A build is another matter: a guest on 4 KiB host pages and a virtiofs root costs a compile about 1.45 to 2.3 times its native time, and emulation costs 16 to 28 times.

A whole build, `bzip2-1.0.8-GCCcore-15.2.0` with the audit on, through `eb-local --cpu-target TARGET --mask ROUTE`, on the same host while other jobs loaded it to 35 to 55 on 32 threads:

| Target | Mode | Wall time | Audit |
|---|---|---|---|
| `x86_64/amd/zen2` | kvm | 71 s | no instruction beyond `x86_64/amd/zen2` |
| `x86_64/amd/zen3` | kvm | 66 s | no instruction beyond `x86_64/amd/zen3` |
| `aarch64/neoverse_v1` | tcg | 191 s | no instruction beyond `aarch64/neoverse_v1` |
| `aarch64/a64fx` | tcg | 283 s | no instruction beyond `aarch64/a64fx` |

The two Arm targets have no `cpuid` profile, so the build runs only under `--mask tcg --mask-allow-archspec-mismatch`.
