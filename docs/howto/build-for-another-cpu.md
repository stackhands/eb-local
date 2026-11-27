<!-- Generated from docs/orgmode/howto/build-for-another-cpu.org by docs/export.el; edit that file. -->

# Build for another CPU target

A build on a Zen 5 machine installs for `x86_64/amd/zen5`.
These steps build the same recipe for `x86_64/amd/zen4`, `x86_64/amd/zen3`, or an Intel target such as `x86_64/intel/icelake`, on that machine, so the tree is installed in the subdirectory the nodes of that target read.

## Before you start

-   eb-local that builds on this machine, as [Install software on top of EESSI with EasyBuild](install-software.md) describes; on a workstation without Slurm, add `--workstation`.
-   A C compiler (`cc`), `unshare` and `mount` on `PATH`, for the `cpuid` route.
-   The easyconfig of the package. Here it is `zlib-2.3.2-GCCcore-15.2.0.eb`.

## Check what this machine can present

```bash
eb-local doctor --cpu-target zen4
```

The lines under `host:` say whether CPUID faulting works (AMD CPUs need Linux 6.17 or later), whether `/dev/kvm` and the QEMU binaries exist, and the last line says which route `--mask auto` takes for the target.
A target with no mask profile, or a host that cannot present it, shows as a `warn` line with the reason.

## Build

```bash
eb-local --workstation --cpu-target zen4 zlib-2.3.2-GCCcore-15.2.0.eb --robot
```

`zen4` means `x86_64/amd/zen4`; the full subdirectory works too, and a short name that two architectures share, such as `generic`, needs the architecture.
Before `eb` starts, the build prints one line per check, all inside the mask:

```text
eb-local: --cpu-target x86_64/amd/zen4, cpuid route (CPUID faulting, namespaced /proc/cpuinfo)
eb-local: preflight ok: /dev/fd exists
eb-local: preflight ok: EESSI archdetect names x86_64/amd/zen4
eb-local: preflight ok: archspec names zen4
eb-local: preflight ok: gcc -march=native is znver4
eb-local: preflight ok: CPUID vendor is AuthenticAMD
eb-local: preflight ok: CPUID faulting is active
```

A line that says `FAILED` stops the build before any compile.
The package installs below `<prefix>/versions/2026.06/software/linux/x86_64/amd/zen4/`.

`eb-local --explain --cpu-target zen4 ...` prints the route and the variables it sets, and runs nothing.

## Read the record of how it was built

Each directory the build installed has `easybuild/eb-local-build-mode.json`:

```json
{
  "cpu_target": "x86_64/amd/zen4",
  "route": "cpuid",
  "profile": "x86_64/amd/zen4",
  "host_cpu": "AMD Ryzen 9 9950X 16-Core Processor",
  "kernel": "7.0.13-arch1-1-rg",
  "eb_local_version": "3.5.0",
  "isa_audit": "pass"
}
```

`isa_audit` is `skipped` with `--no-audit`.
The audit, `eb-local audit-isa DIR --target TARGET`, looks for instructions the target does not have; a failure fails the run and the installed tree stays for inspection.

## When a build refuses

| Message | Meaning |
|---|---|
| `CPUID faulting is not available` | The kernel cannot make `CPUID` fault. Use `--mask kvm` on the same architecture, or run on a newer kernel. |
| `the zen4 profile cannot be shown on a GenuineIntel CPU` | The profile for an AMD target keeps the host's vendor string; an Intel host cannot present it. |
| `this CPU lacks avx512_fp16` | A mask removes features and cannot add them. `sapphirerapids` needs a host that has AVX512-FP16 and AMX. |
| `no mask profile exists for ...` | Only the virtual machine routes can present that target. |
| `preflight FAILED: archspec names ...` | An easyblock that asks archspec would build for another CPU than the tree is labelled for. |
| `/dev/fd is missing` | EESSI's `eessi_archdetect.sh` fails without it and EESSI falls back to the generic target. |
| `__vm-run` | This eb-local has no virtual machine helper; the `kvm` and `tcg` routes refuse. |

## GROMACS and Intel targets

GROMACS chooses the SIMD level of a CPU whose brand string says Intel by timing AVX-512 FMA loops.
A Zen 5 core measures one unit and GROMACS picks `AVX2_256`, so an Ice Lake tree built there would be an AVX2 build, unlike the tree EESSI ships.
A `--cpu-target` build adds `-DGMX_SIMD` from the target to every GROMACS configure line (`AVX_512` for `skylake_avx512`, `cascadelake`, `icelake`, `sapphirerapids`, `zen4` and `zen5`; `AVX2_256` for `haswell`, `zen2` and `zen3`), unless the easyconfig sets it.
The EasyBuild log of the build says `eb-local: setting GMX_SIMD=LEVEL for CPU target TARGET`.

## What the mask does not reach

-   Statically linked programs, and code that runs before the dynamic loader's constructors, see the real CPU.
-   On x86\_64, the `cpuid` route masks the CPUID instruction only. `XGETBV` is not trapped, so a feature that GCC reads from the extended control registers, such as AMX, stays as the host has it.
-   On aarch64 the kernel's emulated reads of ID registers cannot be masked; `getauxval` and `/proc/cpuinfo` are.
