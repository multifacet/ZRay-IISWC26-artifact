#!/usr/bin/env python3
"""Apply the SPEC ROI marker patches, after verifying the target is pristine.

SPEC CPU2017 is licensed and its sources cannot be redistributed with this
artifact, so the ROI annotations ship as zero-context diffs instead of as
modified files. Zero-context hunks give `patch` nothing to validate against, so
the SHA256 manifest is what makes this safe: every target file is checked before
any patch is applied, and a mismatch aborts the whole run rather than silently
placing markers at the wrong lines.

Targets are resolved one of two ways:

  --spec PATH --label NAME   patch each workload's SPEC build directory,
                             benchspec/CPU/<workload>/build/build_base_<label>-m64.0000
  --dest DIR                 patch DIR/<workload>/... (used by the test suite)
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROI = HERE / "roi"


def load_manifest():
    entries = []
    for line in (ROI / "manifest.sha256").read_text().splitlines():
        if line.strip():
            digest, rel = line.split(None, 1)
            entries.append((digest, rel.strip()))
    return entries


def target_dir(args, workload):
    if args.dest:
        return Path(args.dest) / workload
    return (Path(args.spec) / "benchspec" / "CPU" / workload / "build"
            / f"build_base_{args.label}-m64.0000")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", help="SPEC installation root")
    ap.add_argument("--label", default="zray", help="SPEC config label (default: zray)")
    ap.add_argument("--dest", help="patch DIR/<workload>/... instead of SPEC build dirs")
    ap.add_argument("--check-only", action="store_true",
                    help="verify checksums and exit without patching")
    ap.add_argument("--only", action="append", metavar="WORKLOAD",
                    help="restrict to these workloads (repeatable); default is all")
    args = ap.parse_args()

    if not args.dest and not args.spec:
        ap.error("one of --spec or --dest is required")

    entries = load_manifest()
    if args.only:
        wanted = set(args.only)
        entries = [e for e in entries if e[1].split("/", 1)[0] in wanted]
        if not entries:
            ap.error(f"no patches match {sorted(wanted)}")

    # Phase 1: verify every target before touching any of them, so a partially
    # patched tree is never left behind.
    problems = []
    for digest, rel in entries:
        workload = rel.split("/", 1)[0]
        inner = rel.split("/", 1)[1]
        path = target_dir(args, workload) / inner
        if not path.exists():
            problems.append(f"missing: {path}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            problems.append(f"checksum mismatch: {rel}\n    expected {digest}\n    found    {actual}")

    if problems:
        print(f"{len(problems)} of {len(entries)} target files are not pristine:\n",
              file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print("\nThe ROI patches are pinned to SPEC CPU2017v1.0.2 and are applied to a\n"
              "freshly built tree. If this tree was already patched, rebuild it first.",
              file=sys.stderr)
        return 1

    print(f"verified {len(entries)} pristine source files")
    if args.check_only:
        return 0

    # Phase 2: apply. -p2 strips the leading "a/<workload>/" so paths resolve
    # relative to each workload's directory.
    applied = 0
    for _, rel in entries:
        workload = rel.split("/", 1)[0]
        patch = ROI / f"{rel}.patch"
        cwd = target_dir(args, workload)
        r = subprocess.run(["patch", "-p2", "-s", "-i", str(patch)],
                           cwd=cwd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"FAILED to apply {rel}\n{r.stdout}{r.stderr}", file=sys.stderr)
            return 1
        applied += 1

    print(f"applied {applied} ROI patches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
