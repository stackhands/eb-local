"""EasyBuild hooks for `eb-local --cpu-target`.

The site's own hooks (EASYBUILD_HOOKS as EESSI-extend sets it, passed in
EB_LOCAL_BASE_HOOKS) are loaded and re-exported unchanged, and one rule is
added on top: GROMACS gets -DGMX_SIMD from the CPU target.

GROMACS picks the SIMD level of an x86_64 CPU whose brand string says Intel by
timing AVX-512 FMA loops, and a host with one 512-bit FMA unit (Zen 5) measures
AVX2. A tree built there for an Intel AVX-512 target would hold an AVX2 build.
The level follows the target instead, as it does in EESSI's own trees.
"""
import importlib.util
import os

from easybuild.tools.build_log import print_msg

GROMACS_SIMD_BY_CPU_TARGET = {
    'x86_64/amd/zen2': 'AVX2_256',
    'x86_64/amd/zen3': 'AVX2_256',
    'x86_64/amd/zen4': 'AVX_512',
    'x86_64/amd/zen5': 'AVX_512',
    'x86_64/intel/haswell': 'AVX2_256',
    'x86_64/intel/skylake_avx512': 'AVX_512',
    'x86_64/intel/cascadelake': 'AVX_512',
    'x86_64/intel/icelake': 'AVX_512',
    'x86_64/intel/sapphirerapids': 'AVX_512',
}

_base = None
_base_path = os.environ.get('EB_LOCAL_BASE_HOOKS', '')
if _base_path:
    _spec = importlib.util.spec_from_file_location('eb_local_base_hooks', _base_path)
    _base = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_base)
    for _name in dir(_base):
        if _name.endswith('_hook') and callable(getattr(_base, _name)):
            globals()[_name] = getattr(_base, _name)


def pre_configure_hook(self, *args, **kwargs):
    """The site's pre-configure hook, then the GROMACS SIMD rule."""
    if _base is not None and hasattr(_base, 'pre_configure_hook'):
        _base.pre_configure_hook(self, *args, **kwargs)
    if self.name == 'GROMACS':
        cpu_target = os.environ.get('EB_LOCAL_CPU_TARGET', '')
        simd = GROMACS_SIMD_BY_CPU_TARGET.get(cpu_target)
        if simd and '-DGMX_SIMD=' not in self.cfg['configopts']:
            print_msg("eb-local: setting GMX_SIMD=%s for CPU target %s", simd, cpu_target, log=self.log)
            self.cfg.update('configopts', '-DGMX_SIMD=%s' % simd)
