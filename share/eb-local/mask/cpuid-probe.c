/*
 * cpuid-probe: print what this process sees of the CPU, for the preflight of
 * a masked build. Run under the preload library it prints the masked view.
 *
 * x86_64: `vendor=NAME family=N model=N faulting=on|off`, from CPUID leaves 0
 * and 1 (family and model as the kernel computes them) and from
 * arch_prctl(ARCH_GET_CPUID). aarch64: `hwcap=0xH hwcap2=0xH`.
 */
#define _GNU_SOURCE
#include <stdio.h>

#if defined(__x86_64__)
#include <asm/prctl.h>
#include <cpuid.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void)
{
    unsigned a, b, c, d;
    char vendor[13];
    __cpuid(0, a, b, c, d);
    memcpy(vendor, &b, 4);
    memcpy(vendor + 4, &d, 4);
    memcpy(vendor + 8, &c, 4);
    vendor[12] = 0;
    __cpuid(1, a, b, c, d);
    unsigned base = (a >> 8) & 0xf, family = base, model = (a >> 4) & 0xf;
    if (base == 0xf) family += (a >> 20) & 0xff;
    if (base == 0xf || base == 0x6) model += ((a >> 16) & 0xf) << 4;
    /* ARCH_GET_CPUID gives 0 while CPUID faults. */
    long mode = syscall(SYS_arch_prctl, ARCH_GET_CPUID, 0);
    printf("vendor=%s family=%u model=%u faulting=%s\n", vendor, family, model, mode == 0 ? "on" : "off");
    return 0;
}
#else
#include <sys/auxv.h>

int main(void)
{
    printf("hwcap=%#lx hwcap2=%#lx\n", getauxval(AT_HWCAP), getauxval(AT_HWCAP2));
    return 0;
}
#endif
