#!/usr/bin/env python3
"""Turn a SPEC benchmark's make.out into ZRay, Pin, and control build scripts.

SPEC records every compile and link command it issued in make.out, with all
portability and optimization flags already resolved. That file is the contract
this script depends on: each variant re-runs those exact commands, changed only
where instrumentation requires it.

  * compiles emit LLVM IR (-S -emit-llvm) instead of objects
  * the link becomes llvm-link, then opt, then a final codegen link
  * ZRay additionally loads the pass and links the ZRay runtime IR

The final codegen link reuses the optimization flags from SPEC's own link line,
so the three variants are built through an identical pipeline and differ only in
instrumentation. Dropping -O2 here would silently produce -O0 codegen and inflate
every overhead number measured against the control.

Intermediate IR is named per variant (foo.zray.ll, foo.pin.ll, ...) so the three
builds share a directory without racing.
"""
import argparse
import re
import shlex
import sys
from pathlib import Path

COMPILE = re.compile(r"^(.*?)\s-c\s+-o\s+(\S+\.o)\s+(.*)$")

VARIANTS = {
    # name:      (extra compile flags, suffix on the produced binary)
    "baseline": ([], "baseline"),
    "zray": (["-DZRAY_ROI_INSTRUMENTATION"], "zray"),
    # -include forces the marker declarations to the top of every translation
    # unit. The in-file #include sits wherever the annotation author put it, which
    # in x264's mc.c is *after* two of the marker calls; C would then invent
    # implicit declarations and reject the real ones as conflicting. pinroi.h is
    # two prototypes with no include guard, so including it twice is harmless.
    "pin": (["-DPIN_ROI_INSTRUMENTATION", "-I$PIN_ROI_DIR",
             "-include", "pinroi.h"], "pin"),
}


def find_make_out(bd):
    """Locate the command list for the workload's primary binary.

    Benchmarks that build a single executable get make.out. Those that also build
    helpers -- x264 ships ldecod_r, and several ship an imagevalidate_NNN output
    checker -- get one make.<binary>.out per executable instead. Only the primary
    binary carries ROI markers, so the helpers are left as SPEC built them.
    """
    single = bd / "make.out"
    if single.exists():
        return single

    workload = bd.parent.parent.name          # e.g. 525.x264_r
    stem = workload.split(".", 1)[1]          # e.g. x264_r
    named = bd / f"make.{stem}.out"
    if named.exists():
        return named

    cands = sorted(p.name for p in bd.glob("make.*.out") if p.name != "make.clean.out")
    raise SystemExit(f"{bd}: no make.out or make.{stem}.out; found {cands}")


def parse(make_out):
    compiles, link = [], None
    for raw in make_out.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        m = COMPILE.match(line)
        if m:
            compiles.append((m.group(1), m.group(2), m.group(3)))
        else:
            link = line
    if not compiles or link is None:
        raise SystemExit(f"{make_out}: expected compile lines and a link line")
    return compiles, link


def split_link(link):
    toks = shlex.split(link)
    driver, rest = toks[0], toks[1:]
    objs, flags, binary = [], [], None
    i = 0
    while i < len(rest):
        t = rest[i]
        if t == "-o":
            binary = rest[i + 1]
            i += 2
            continue
        (objs if t.endswith(".o") else flags).append(t)
        i += 1
    if binary is None:
        raise SystemExit("link line has no -o")
    return driver, objs, flags, binary


def emit(variant, compiles, link, out_path):
    defines, suffix = VARIANTS[variant]
    driver, objs, flags, binary = split_link(link)

    # C++ programs link with clang++ and need the C++-mangled marker library.
    pin_lib = "-lpinroi-cc" if driver.endswith("++") else "-lpinroi"

    def ir_name(obj):
        return obj[:-2] + f".{suffix}.ll"

    L = [
        "#!/bin/bash",
        "# Generated from make.out by spec/make-build-scripts.py -- do not edit.",
        f"# Variant: {variant}",
        "set -e",
        "",
    ]

    for cc, obj, tail in compiles:
        parts = shlex.split(cc)
        cmd = [parts[0]] + defines + parts[1:]
        L.append(" ".join(cmd) + f" -S -emit-llvm -o {ir_name(obj)} {tail}")

    irs = " ".join(ir_name(o) for o in objs)
    linked = f"linked_{binary}.{suffix}.ll"
    optimized = f"optimized_{binary}.{suffix}.ll"

    L += ["", f'"$CUSTOM_LINK" {irs} -o {linked}']

    if variant == "zray":
        L.append(f'"$CUSTOM_OPT" -enable-new-pm=0 -O2 -mem2reg '
                 f'-load "$ZRAY_BIN_PATH/libzray.so" -zray -S {linked} -o {optimized}')
        final = f"linked_optimized_{binary}.{suffix}.ll"
        L.append(f'"$CUSTOM_LINK" "$ZRAY_BIN_PATH/zray_runtime.ll" {optimized} -S -o {final}')
    else:
        L.append(f'"$CUSTOM_OPT" -enable-new-pm=0 -O2 -mem2reg -S {linked} -o {optimized}')
        final = optimized

    # Libraries must follow the input they satisfy: ld resolves left to right, so
    # an archive named before the IR contributes nothing and its symbols come out
    # undefined. SPEC's own link line puts -lm first, which happens to work only
    # because libm is shared.
    opts = [f for f in flags if not f.startswith("-l")]
    libs = [f for f in flags if f.startswith("-l")]

    if variant == "pin":
        libs += ["-L$PIN_ROI_DIR", pin_lib]
    if variant == "zray":
        # zray_runtime.ll is C++ and pulls in std::thread and the Itanium ABI's
        # exception personality, neither of which the C driver would link.
        libs += ["-lstdc++", "-lpthread"]

    L.append(f'{driver} -L/usr/lib/llvm-15/lib/ {" ".join(opts)} '
             f'{final} {" ".join(libs)} -o {binary}_{suffix}')
    L.append("")

    out_path.write_text("\n".join(L))
    out_path.chmod(0o755)
    return binary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-dir", required=True)
    args = ap.parse_args()

    bd = Path(args.build_dir)
    compiles, link = parse(find_make_out(bd))
    for variant in VARIANTS:
        binary = emit(variant, compiles, link, bd / f"{variant}-build.sh")
    # Recorded for the orchestrator: the binary stem varies per workload and is
    # only discoverable from SPEC's link line.
    (bd / ".zray-binary").write_text(binary + "\n")
    print(f"{bd.name}: {len(compiles)} compiles -> {binary} "
          f"[{', '.join(VARIANTS)}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
