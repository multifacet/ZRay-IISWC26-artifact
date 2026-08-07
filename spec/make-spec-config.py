#!/usr/bin/env python3
"""Derive the artifact's SPEC config from the one shipped with ZRay.
"""
import argparse
import re
import sys
from pathlib import Path

SECTION = re.compile(r"^\S.*:\s*(#.*)?$")
OPT = re.compile(r"^(\s*(?:C|CXX)OPTIMIZE\s*=\s*)-O3\b(.*)$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="ZRay's spec-cfg template")
    ap.add_argument("--spec", required=True, help="SPEC installation root")
    ap.add_argument("--out", required=True, help="config file to write")
    args = ap.parse_args()

    lines = Path(args.source).read_text().splitlines()
    out, in_base, edits = [], False, {"base_dir": 0, "opt": 0}

    for line in lines:
        if line.startswith("    BASE_DIR") and "=" in line:
            indent, _ = line.split("=", 1)
            out.append(f"{indent}= {args.spec}")
            edits["base_dir"] += 1
            continue

        # Track which tuning section we are in so only base is downgraded.
        if SECTION.match(line):
            in_base = line.strip().startswith("default=base:")

        if in_base:
            m = OPT.match(line)
            if m:
                out.append(f"{m.group(1)}-O2{m.group(2)}")
                edits["opt"] += 1
                continue

        out.append(line)

    if edits["base_dir"] != 1 or edits["opt"] != 2:
        print(f"unexpected template: {edits} (want base_dir=1, opt=2)", file=sys.stderr)
        return 1

    # At -O2 glibc emits an `extern inline` out-of-line definition of vprintf in
    # every translation unit. SPEC tolerates the duplicates at ELF level with
    # -z muldefs, but this artifact links the IR with llvm-link first, which has
    # no such option and rejects the module outright. -fgnu89-inline restores the
    # semantics where `extern inline` emits no definition at all. SPEC documents
    # this same flag for 502.gcc_r.
    out += [
        "",
        "#--------  Artifact additions  ------------------------------------------------",
        "502.gcc_r:",
        "    CPORTABILITY = -fgnu89-inline",
        "",
        # parest contains `s.c_str() != '\\0'`, comparing a pointer against a char.
        # C++03 counted '\\0' as a null pointer constant so this compiled; C++11
        # narrowed that rule to integer literals and nullptr, making it an error
        # under clang's modern default. gnu++98 restores the original meaning
        # rather than changing the comparison's semantics.
        "510.parest_r:",
        "    CXXPORTABILITY = -std=gnu++98",
    ]

    Path(args.out).write_text("\n".join(out) + "\n")
    print(f"wrote {args.out}  (BASE_DIR set, {edits['opt']} base flags -O3 -> -O2, "
          f"gcc_r portability flag added)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
