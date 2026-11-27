/*
 * armmask: present another aarch64 CPU's capabilities to the dynamically
 * linked processes of a tree, without a VM.
 *
 * aarch64 software learns the CPU three ways: getauxval(AT_HWCAP/AT_HWCAP2)
 * (Highway, most runtime dispatchers), /proc/cpuinfo (GCC -mcpu=native,
 * archspec, EESSI archdetect, OpenBLAS getarch), and MRS reads of ID
 * registers, which the kernel emulates without a signal. This library covers
 * the first by interposing getauxval; eb-local covers the second with a
 * bind-mounted cpuinfo. The third cannot be reached from userspace.
 *
 * ARMMASK_HWCAP and ARMMASK_HWCAP2 hold the words to keep, in hexadecimal;
 * the result is the real word AND the kept one. Without ARMMASK_HWCAP the
 * library does nothing.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/auxv.h>

typedef unsigned long (*getauxval_fn)(unsigned long);

unsigned long getauxval(unsigned long type)
{
    static getauxval_fn real;
    if (!real)
        real = (getauxval_fn)dlsym(RTLD_NEXT, "getauxval");
    unsigned long v = real(type);
    if (type != AT_HWCAP && type != AT_HWCAP2)
        return v;
    const char *on = getenv("ARMMASK_HWCAP");
    const char *keep = getenv(type == AT_HWCAP ? "ARMMASK_HWCAP" : "ARMMASK_HWCAP2");
    if (!on || !*on || !keep)
        return v;
    return v & strtoul(keep, NULL, 16);
}
