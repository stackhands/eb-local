#!/usr/bin/env python3
"""Write the data files `eb-local audit-isa` reads, into src/isa/.

    python3 -m venv v && v/bin/pip install iced-x86==1.22.0
    v/bin/python tools/isa_tables/gen.py

Inputs, all in this directory except iced-x86:
  microarchitectures.json  archspec-json cpu/microarchitectures.json
  gcc-march-macros.tsv     predefined macros of gcc -march=NAME (GCC 16.2.1)
  iced-x86 1.22.0          every x86-64 instruction form: mnemonic, encoding,
                           vector width and the CPUID features it needs

Outputs:
  x86_features.tsv   mnemonic, encoding (L legacy, V VEX, E EVEX, X XOP),
                     vector width, features the form needs. A feature with a
                     leading ? has no entry in X86_FEATURES below and is
                     reported as unclassified.
  aarch64_rules.tsv  mnemonic pattern, operand tests, feature; first match wins
  targets.tsv        EESSI software subdirectory, architecture, features it has
"""
import json
import os
import re
import sys
from collections import defaultdict

from iced_x86 import Code, CpuidFeature, Instruction

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "src", "isa")

ARCHSPEC_COMMIT = "47d41380213e0d86870a302a3927036fbd6c7b68"
ARCHSPEC_DATE = "2026-11-23"
ICED_VERSION = "1.22.0"

# iced feature name (normalised) -> the name used in reports and allow lists
ALIASES = {
    "bmi1": "bmi", "cetss": "shstk", "cetibt": "ibt", "monitorx": "mwaitx",
    "pclmulqdq": "pclmul", "prefetchw": "prfchw", "prefetchiti": "prefetchi",
    "aeskle": "kl", "aeskle256": "widekl", "amxfp16": "amxfp16",
    "rdrand": "rdrnd", "d3now": "3dnow", "sgx1": "sgx",
}

# Baseline of x86-64 and instructions every compiler may emit without an -m
# flag: never a violation.
BASELINE = {
    "intel8086", "intel8086only", "intel186", "intel286", "intel286only",
    "intel386", "intel386only", "intel486", "intel486a", "x64", "fpu",
    "fpu287", "fpu387", "cmov", "cx8", "mmx", "sse", "sse2", "pause",
    "multibytenop", "syscall", "rdtsc", "rdtscp", "cpuid", "cx16", "lahfsahf",
    "lahf_sahf", "sahf", "fxsr", "clfsh", "nop", "tsc", "msr", "sysenter",
    "smm", "invpcid", "cmpxchg16b", "ibt", "rdpmc", "tsc", "sep", "oss",
    "intel386a0only", "intel486aonly", "fpu287xlonly", "fpu387slonly",
}

# Features the audit can judge: normalised name -> (archspec flags, GCC
# macros). A target has the feature when either source lists it.
X86_FEATURES = {
    "sse3": (["sse3", "pni"], ["SSE3"]),
    "ssse3": (["ssse3"], ["SSSE3"]),
    "sse41": (["sse4_1"], ["SSE4_1"]),
    "sse42": (["sse4_2"], ["SSE4_2"]),
    "sse4a": (["sse4a"], ["SSE4A"]),
    "avx": (["avx"], ["AVX"]),
    "avx2": (["avx2"], ["AVX2"]),
    "fma": (["fma"], ["FMA"]),
    "fma4": (["fma4"], []),
    "f16c": (["f16c"], ["F16C"]),
    "bmi": (["bmi1"], ["BMI"]),
    "bmi2": (["bmi2"], ["BMI2"]),
    "lzcnt": (["abm", "lzcnt"], ["LZCNT"]),
    "popcnt": (["popcnt"], ["POPCNT"]),
    "movbe": (["movbe"], ["MOVBE"]),
    "aes": (["aes"], ["AES"]),
    "pclmul": (["pclmulqdq"], ["PCLMUL"]),
    "rdrnd": (["rdrand"], ["RDRND"]),
    "rdseed": (["rdseed"], ["RDSEED"]),
    "adx": (["adx"], ["ADX"]),
    "sha": (["sha_ni"], ["SHA"]),
    "xsave": (["xsave"], ["XSAVE"]),
    "xsaveopt": (["xsaveopt"], ["XSAVEOPT"]),
    "xsavec": (["xsavec"], ["XSAVEC"]),
    "xsaves": ([], ["XSAVES"]),
    "clflushopt": (["clflushopt"], ["CLFLUSHOPT"]),
    "clwb": (["clwb"], ["CLWB"]),
    "clzero": (["clzero"], ["CLZERO"]),
    "mwaitx": ([], ["MWAITX"]),
    "wbnoinvd": ([], ["WBNOINVD"]),
    "rdpid": (["rdpid"], ["RDPID"]),
    "fsgsbase": (["fsgsbase"], ["FSGSBASE"]),
    "prfchw": (["3dnowprefetch"], ["PRFCHW"]),
    "pku": (["pku"], ["PKU"]),
    "vaes": (["vaes"], ["VAES"]),
    "vpclmulqdq": (["vpclmulqdq"], ["VPCLMULQDQ"]),
    "gfni": (["gfni"], ["GFNI"]),
    "avx512f": (["avx512f"], ["AVX512F"]),
    "avx512dq": (["avx512dq"], ["AVX512DQ"]),
    "avx512cd": (["avx512cd"], ["AVX512CD"]),
    "avx512bw": (["avx512bw"], ["AVX512BW"]),
    "avx512vl": (["avx512vl"], ["AVX512VL"]),
    "avx512er": (["avx512er"], []),
    "avx512pf": (["avx512pf"], []),
    "avx5124fmaps": (["avx512_4fmaps"], []),
    "avx5124vnniw": (["avx512_4vnniw"], []),
    "avx512ifma": (["avx512ifma"], ["AVX512IFMA"]),
    "avx512vbmi": (["avx512vbmi"], ["AVX512VBMI"]),
    "avx512vbmi2": (["avx512_vbmi2"], ["AVX512VBMI2"]),
    "avx512vnni": (["avx512_vnni"], ["AVX512VNNI"]),
    "avx512bitalg": (["avx512_bitalg"], ["AVX512BITALG"]),
    "avx512vpopcntdq": (["avx512_vpopcntdq"], ["AVX512VPOPCNTDQ"]),
    "avx512bf16": (["avx512_bf16"], ["AVX512BF16"]),
    "avx512fp16": (["avx512_fp16"], ["AVX512FP16"]),
    "avx512vp2intersect": (["avx512_vp2intersect"], ["AVX512VP2INTERSECT"]),
    "avxvnni": (["avx_vnni"], ["AVXVNNI"]),
    "amxbf16": (["amx_bf16"], ["AMX_BF16"]),
    "amxtile": (["amx_tile"], ["AMX_TILE"]),
    "amxint8": (["amx_int8"], ["AMX_INT8"]),
    "amxfp16": (["amx_fp16"], []),
    "movdiri": (["movdiri"], ["MOVDIRI"]),
    "movdir64b": (["movdir64b"], ["MOVDIR64B"]),
    "cldemote": (["cldemote"], ["CLDEMOTE"]),
    "enqcmd": (["enqcmd"], ["ENQCMD"]),
    "serialize": (["serialize"], ["SERIALIZE"]),
    "waitpkg": (["waitpkg"], ["WAITPKG"]),
    "tsxldtrk": (["tsxldtrk"], ["TSXLDTRK"]),
    "ptwrite": ([], ["PTWRITE"]),
    "sgx": ([], ["SGX"]),
    "pconfig": ([], ["PCONFIG"]),
    "prefetchi": (["prefetchi"], ["PREFETCHI"]),
    "xop": (["xop"], []),
    "tbm": (["tbm"], []),
    "lwp": (["lwp"], []),
    "3dnow": (["3dnow"], []),
    "d3nowext": (["3dnowext"], []),
    "rtm": (["rtm"], []),
    "hle": (["hle"], []),
    "hleorrtm": (["hle", "rtm"], []),
    "mpx": (["mpx"], []),
    "shstk": (["shstk", "cet_ss"], []),
    "sha512": (["sha512"], []),
    "sm3": (["sm3"], []),
    "sm4": (["sm4"], []),
    "avxifma": (["avx_ifma"], []),
    "avxneconvert": (["avx_ne_convert"], []),
    "avxvnniint8": (["avx_vnni_int8"], []),
    "avxvnniint16": (["avx_vnni_int16"], []),
    "amxcomplex": (["amx_complex"], []),
    "uintr": (["uintr"], []),
    "kl": (["kl"], []),
    "widekl": (["widekl"], []),
    "cmpccxadd": (["cmpccxadd"], []),
    "raoint": (["rao_int"], []),
    "pcommit": ([], []),
    "clfsh": ([], []),
    "invpcid": ([], []),
    "mpxx": ([], []),
}
# A feature whose presence implies another (the x86 ISA is a chain here).
X86_IMPLIES = {
    "avx2": ["avx"], "avx": ["sse42"], "sse42": ["sse41"], "sse41": ["ssse3"],
    "ssse3": ["sse3"], "fma": ["avx"], "f16c": ["avx"], "avx512f": ["avx2"],
    "avx512vl": ["avx512f"], "avx512bw": ["avx512f"], "avx512dq": ["avx512f"],
    "avx512cd": ["avx512f"], "vaes": ["aes"], "vpclmulqdq": ["pclmul"],
}

# EESSI software subdirectory -> (archspec name, gcc -march name)
X86_TARGETS = {
    "x86_64/generic": ("x86_64", "x86-64"),
    "x86_64/amd/zen2": ("zen2", "znver2"),
    "x86_64/amd/zen3": ("zen3", "znver3"),
    "x86_64/amd/zen4": ("zen4", "znver4"),
    "x86_64/amd/zen5": ("zen5", "znver5"),
    "x86_64/intel/haswell": ("haswell", "haswell"),
    "x86_64/intel/skylake_avx512": ("skylake_avx512", "skylake-avx512"),
    "x86_64/intel/cascadelake": ("cascadelake", "cascadelake"),
    "x86_64/intel/icelake": ("icelake", "icelake-server"),
    "x86_64/intel/sapphirerapids": ("sapphirerapids", "sapphirerapids"),
}
AARCH64_TARGETS = {
    "aarch64/generic": "aarch64",
    "aarch64/neoverse_n1": "neoverse_n1",
    "aarch64/neoverse_v1": "neoverse_v1",
    "aarch64/neoverse_v2": "neoverse_v2",
    "aarch64/a64fx": "a64fx",
    "aarch64/nvidia/grace": "neoverse_v2",
    "aarch64/google/axion": "neoverse_v2",
    "aarch64/aws/graviton2": "neoverse_n1",
    "aarch64/aws/graviton3": "neoverse_v1",
    "aarch64/aws/graviton4": "neoverse_v2",
}

# archspec aarch64 flag -> feature of the rules below
AARCH64_FLAGS = {
    "atomics": "lse", "crc32": "crc", "aes": "aes", "pmull": "pmull",
    "sha1": "sha1", "sha2": "sha2", "sha3": "sha3", "sha512": "sha512",
    "sm3": "sm3", "sm4": "sm4", "asimddp": "dotprod", "asimdrdm": "rdm",
    "fphp": "fp16", "asimdhp": "fp16", "asimdfhm": "fhm", "fcma": "fcma",
    "jscvt": "jscvt", "lrcpc": "rcpc", "ilrcpc": "rcpc2", "flagm": "flagm",
    "flagm2": "flagm2", "sve": "sve", "sve2": "sve2", "svei8mm": "sve-i8mm",
    "svebf16": "sve-bf16", "i8mm": "i8mm", "bf16": "bf16",
    "svebitperm": "sve2-bitperm", "sveaes": "sve2-aes",
    "svesha3": "sve2-sha3", "svesm4": "sve2-sm4", "svepmull": "sve2-pmull",
    "f32mm": "f32mm", "f64mm": "f64mm", "frint": "frint", "mte": "mte",
    "paca": "pauth", "sme": "sme", "rng": "rng",
}
AARCH64_IMPLIES = {
    "sve2": ["sve"], "sve2-bitperm": ["sve2"], "sve2-aes": ["sve2"],
    "sve2-sha3": ["sve2"], "sve2-sm4": ["sve2"], "sve2-pmull": ["sve2"],
    "sve-i8mm": ["sve"], "sve-bf16": ["sve"], "f32mm": ["sve"],
    "f64mm": ["sve"], "fhm": ["fp16"], "rcpc2": ["rcpc"], "flagm2": ["flagm"],
    "sha512": ["sha2"], "sha3": ["sha512"], "pmull": ["aes"],
}


def norm(name):
    return name.lower().replace("_", "").replace("-", "").replace(".", "")


def feature_names():
    return {v: k for k, v in vars(CpuidFeature).items()
            if isinstance(v, int) and not k.startswith("_")}


def code_names():
    return {v: k for k, v in vars(Code).items()
            if isinstance(v, int) and not k.startswith("_")}


def mnemonic_names():
    from iced_x86 import Mnemonic
    return {v: k.lower() for k, v in vars(Mnemonic).items()
            if isinstance(v, int) and not k.startswith("_")}


ENC = {0: "L", 1: "V", 2: "E", 3: "X", 4: "L"}
CLOSE_KEEP = {"shstk"}


def x86_rows():
    fn, cn, mn = feature_names(), code_names(), mnemonic_names()
    groups = defaultdict(list)
    ins = Instruction()
    for cid, cname in cn.items():
        ins.code = cid
        enc = ENC.get(int(ins.encoding))
        if enc is None:
            continue
        width = 0
        for token, w in (("XMM", 128), ("YMM", 256), ("ZMM", 512)):
            if token in cname:
                width = max(width, w)
        feats = set()
        for f in ins.cpuid_features():
            n = norm(fn[f])
            n = ALIASES.get(n, n)
            if n not in BASELINE:
                feats.add(n)
        groups[(mn[int(ins.mnemonic)], enc, width)].append(frozenset(feats))
    rows, ambiguous = [], 0
    for key in sorted(groups):
        sets = groups[key]
        keep = frozenset.intersection(*sets)
        if any(s != keep for s in sets):
            ambiguous += 1
            if not keep and key[1] != "L":
                # Forms of one vector mnemonic that need different sets
                # (vbroadcastss from memory is AVX, from a register AVX2):
                # the smaller requirement, so that no form is reported
                # against a target that has the instruction.
                keep = min((s for s in sets if s), key=lambda s: (len(s), sorted(s)), default=keep)
        if not keep:
            continue
        shown = ",".join(sorted(f if f in X86_FEATURES else "?" + f for f in keep))
        rows.append(f"{key[0]}\t{key[1]}\t{key[2]}\t{shown}")
    return rows, ambiguous


def closure(feats, implies):
    out = set(feats)
    todo = list(out)
    while todo:
        for g in implies.get(todo.pop(), []):
            if g not in out:
                out.add(g)
                todo.append(g)
    return out


def x86_targets(arch):
    macros = {}
    for line in open(os.path.join(HERE, "gcc-march-macros.tsv")):
        if line.startswith("#") or not line.strip():
            continue
        name, rest = line.rstrip("\n").split("\t")
        macros[name] = set(rest.split())
    rows = []
    for sub, (asname, gccname) in X86_TARGETS.items():
        flags = set(arch[asname]["features"])
        have = set()
        for feat, (fl, ms) in X86_FEATURES.items():
            if any(f in flags for f in fl) or any(m in macros[gccname] for m in ms):
                have.add(feat)
        rows.append(f"{sub}\tx86_64\t{','.join(sorted(closure(have, X86_IMPLIES)))}")
    return rows


def aarch64_targets(arch):
    rows = []
    for sub, asname in AARCH64_TARGETS.items():
        have = {AARCH64_FLAGS[f] for f in arch[asname]["features"] if f in AARCH64_FLAGS}
        rows.append(f"{sub}\taarch64\t{','.join(sorted(closure(have, AARCH64_IMPLIES)))}")
    return rows


def expand(masks, suffixes):
    return [m + s for m in masks for s in suffixes]


def aarch64_rules():
    r = []

    def rule(mn, cond, feat):
        r.append(f"{mn}\t{cond}\t{feat}")

    # SVE2 forms first: a mnemonic with a z or p register operand.
    for m in ("bdep", "bext", "bgrp"):
        rule(m, "sve", "sve2-bitperm")
    for m in ("aese", "aesd", "aesmc", "aesimc"):
        rule(m, "sve", "sve2-aes")
    rule("rax1", "sve", "sve2-sha3")
    for m in ("sm4e", "sm4ekey"):
        rule(m, "sve", "sve2-sm4")
    for m in ("pmullb", "pmullt"):
        rule(m, "sve,op=.q", "sve2-pmull")
    sve2 = """histcnt histseg match nmatch whilerw whilewr eorbt eortb eor3 bcax
    xar bsl bsl1n bsl2n nbsl smlalb smlalt umlalb umlalt smlslb
    smlslt umlslb umlslt smullb smullt umullb umullt sqdmlalb sqdmlalt
    sqdmlslb sqdmlslt sqdmullb sqdmullt sqdmlalbt sqdmlslbt sqrdcmlah cmla
    sqcadd uaba saba sabalb sabalt uabalb uabalt sabdlb sabdlt uabdlb uabdlt
    addhnb addhnt raddhnb raddhnt subhnb subhnt rsubhnb rsubhnt rshrnb rshrnt
    shrnb shrnt sqshrnb sqshrnt sqrshrnb sqrshrnt uqshrnb uqshrnt uqrshrnb
    uqrshrnt sqshrunb sqshrunt sqrshrunb sqrshrunt sqxtnb sqxtnt uqxtnb
    uqxtnt sqxtunb sqxtunt sshllb sshllt ushllb ushllt saddlb saddlt uaddlb
    uaddlt ssublb ssublt usublb usublt saddwb saddwt uaddwb uaddwt ssubwb
    ssubwt usubwb usubwt adclb adclt sbclb sbclt urecpe ursqrte
    shadd uhadd shsub uhsub shsubr uhsubr srhadd urhadd suqadd usqadd
    srshl urshl srshlr urshlr sqrshl uqrshl sqshlr
    uqshlr sqrshlr uqrshlr sqrdmlah sqrdmlsh
    addp smaxp sminp umaxp uminp sadalp uadalp faddp fmaxp fminp fmaxnmp
    fminnmp flogb fcvtxnt fcvtnt fcvtlt bfcvtnt cadd""".split()
    for m in sve2:
        rule(m, "sve", "sve2")
    # BF16, I8MM and the matrix multiplies, SVE forms before NEON forms.
    for m in ("bfdot", "bfmmla", "bfcvt", "bfcvtn", "bfcvtn2", "bfmlalb",
              "bfmlalt", "bfmlslb", "bfmlslt"):
        rule(m, "sve", "sve-bf16")
        rule(m, "nosve", "bf16")
    for m in ("smmla", "ummla", "usmmla", "usdot", "sudot"):
        rule(m, "sve", "sve-i8mm")
        rule(m, "nosve", "i8mm")
    rule("fmmla", "sve,op=.d", "f64mm")
    rule("fmmla", "sve,op=.s", "f32mm")
    for m in ("sdot", "udot"):
        rule(m, "nosve", "dotprod")
    # Count and vector-length mnemonics without a z or p operand.
    for m in ("rdvl", "addvl", "addpl", "cntb", "cnth", "cntw", "cntd",
              "incb", "inch", "incw", "incd", "decb", "dech", "decw", "decd",
              "sqincb", "sqinch", "sqincw", "sqincd", "uqincb", "uqinch",
              "uqincw", "uqincd", "sqdecb", "sqdech", "sqdecw", "sqdecd",
              "uqdecb", "uqdech", "uqdecw", "uqdecd", "rdffr", "setffr",
              "wrffr", "rdffrs"):
        rule(m, "", "sve")
    rule("*", "sve", "sve")
    # SME.
    for m in ("smstart", "smstop", "rdsvl", "addsvl", "addspl"):
        rule(m, "", "sme")
    # NEON extensions and system-register features.
    lse = ["cas", "casp", "swp", "ldadd", "ldclr", "ldeor", "ldset", "ldsmax",
           "ldsmin", "ldumax", "ldumin", "stadd", "stclr", "steor", "stset",
           "stsmax", "stsmin", "stumax", "stumin"]
    for base in lse:
        for order in ("", "a", "al", "l"):
            for size in ("", "b", "h"):
                if base == "casp" and size:
                    continue
                if base.startswith("st") and order in ("a", "al"):
                    continue
                rule(base + order + size, "", "lse")
    for m in ("crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch",
              "crc32cw", "crc32cx"):
        rule(m, "", "crc")
    for m in ("aese", "aesd", "aesmc", "aesimc"):
        rule(m, "", "aes")
    rule("pmull", "op=.1q", "pmull")
    rule("pmull2", "op=.1q", "pmull")
    rule("pmull", "op=.1d", "pmull")
    rule("pmull2", "op=.2d", "pmull")
    for m in ("sha1c", "sha1h", "sha1m", "sha1p", "sha1su0", "sha1su1"):
        rule(m, "", "sha1")
    for m in ("sha256h", "sha256h2", "sha256su0", "sha256su1"):
        rule(m, "", "sha2")
    for m in ("sha512h", "sha512h2", "sha512su0", "sha512su1"):
        rule(m, "", "sha512")
    for m in ("eor3", "rax1", "xar", "bcax"):
        rule(m, "", "sha3")
    for m in ("sm3partw1", "sm3partw2", "sm3ss1", "sm3tt1a", "sm3tt1b",
              "sm3tt2a", "sm3tt2b"):
        rule(m, "", "sm3")
    for m in ("sm4e", "sm4ekey"):
        rule(m, "", "sm4")
    for m in ("sqrdmlah", "sqrdmlsh"):
        rule(m, "", "rdm")
    for m in ("fcadd", "fcmla"):
        rule(m, "", "fcma")
    rule("fjcvtzs", "", "jscvt")
    for m in ("fmlal", "fmlal2", "fmlsl", "fmlsl2"):
        rule(m, "", "fhm")
    for m in ("ldaprb", "ldaprh", "ldapr"):
        rule(m, "", "rcpc")
    for m in ("ldapurb", "ldapurh", "ldapur", "ldapursb", "ldapursh",
              "ldapursw", "stlurb", "stlurh", "stlur"):
        rule(m, "", "rcpc2")
    for m in ("cfinv", "setf8", "setf16", "rmif"):
        rule(m, "", "flagm")
    for m in ("axflag", "xaflag"):
        rule(m, "", "flagm2")
    for m in ("frint32z", "frint32x", "frint64z", "frint64x"):
        rule(m, "", "frint")
    for m in ("irg", "gmi", "subp", "subps", "stg", "stzg", "st2g", "stz2g",
              "stgp", "ldg", "ldgm", "stgm", "addg", "subg"):
        rule(m, "", "mte")
    # Pointer authentication outside the hint space (PACIASP and the other
    # hint forms run as NOPs on older cores).
    for m in ("pacia", "pacib", "pacda", "pacdb", "autia", "autib", "autda",
              "autdb", "paciza", "pacizb", "pacdza", "pacdzb", "autiza",
              "autizb", "autdza", "autdzb", "xpaci", "xpacd", "pacga", "retaa",
              "retab", "braa", "brab", "blraa", "blrab", "braaz", "brabz",
              "blraaz", "blrabz", "ldraa", "ldrab", "eretaa", "eretab"):
        rule(m, "", "pauth")
    rule("mrs", "op=rndr", "rng")
    # Half-precision arithmetic: scalar h registers or .4h/.8h arrangements.
    fp16 = """fadd fsub fmul fdiv fmla fmls fmax fmin fmaxnm fminnm fmaxp fminp
    fmaxv fminv fmaxnmv fminnmv fmaxnmp fminnmp faddp fabs fneg fsqrt frecpe
    frecps frecpx frsqrte frsqrts fabd fcmeq fcmge fcmgt fcmle fcmlt facge
    facgt fcmp fcmpe fcsel fccmp fccmpe fmadd fmsub fnmadd fnmsub fnmul fmulx
    frinta frinti frintm frintn frintp frintx frintz scvtf ucvtf fcvtzs
    fcvtzu fcvtas fcvtau fcvtms fcvtmu fcvtns fcvtnu fcvtps fcvtpu fmov
    fmaxnmv""".split()
    for m in fp16:
        rule(m, "nosve,hreg", "fp16")
        rule(m, "nosve,op=.4h", "fp16")
        rule(m, "nosve,op=.8h", "fp16")
    return r


def main():
    arch = json.load(open(os.path.join(HERE, "microarchitectures.json")))["microarchitectures"]
    os.makedirs(OUT, exist_ok=True)
    rows, ambiguous = x86_rows()
    src = (f"# archspec-json commit {ARCHSPEC_COMMIT} ({ARCHSPEC_DATE}), "
           "cpu/microarchitectures.json\n")
    with open(os.path.join(OUT, "x86_features.tsv"), "w") as fh:
        fh.write("# Generated by tools/isa_tables/gen.py from iced-x86 "
                 f"{ICED_VERSION}; do not edit.\n"
                 "# mnemonic, encoding (L legacy, V VEX, E EVEX, X XOP), vector width "
                 "(0 none), features.\n"
                 "# A form whose CPUID features differ between iced codes keeps the "
                 f"features all of them need ({ambiguous} such groups).\n"
                 "# A feature with a leading ? is not classified; the audit counts it "
                 "and does not fail on it.\n")
        fh.write("\n".join(rows) + "\n")
    with open(os.path.join(OUT, "aarch64_rules.tsv"), "w") as fh:
        fh.write("# Generated by tools/isa_tables/gen.py; do not edit.\n"
                 "# mnemonic (a trailing * matches a prefix), operand tests joined by commas, feature.\n"
                 "# Tests: sve (a z or p register operand), nosve, hreg (an h register operand),\n"
                 "# op=TEXT (the operand text holds TEXT). The first matching rule decides;\n"
                 "# a mnemonic with no matching rule needs no feature.\n")
        fh.write("\n".join(aarch64_rules()) + "\n")
    with open(os.path.join(OUT, "targets.tsv"), "w") as fh:
        fh.write("# Generated by tools/isa_tables/gen.py; do not edit.\n"
                 f"{src}"
                 "# GCC 16.2.1 -march=NAME predefined macros add the x86 instruction sets "
                 "archspec does not list for a CPU.\n"
                 "# EESSI software subdirectory, architecture, features the CPU has.\n")
        fh.write("\n".join(x86_targets(arch) + aarch64_targets(arch)) + "\n")
    unmapped = sorted({f.lstrip("?") for r in rows for f in r.split("\t")[3].split(",") if f.startswith("?")})
    print(f"{len(rows)} x86 rows, {ambiguous} ambiguous groups; unclassified features: {' '.join(unmapped)}")


if __name__ == "__main__":
    sys.exit(main())
