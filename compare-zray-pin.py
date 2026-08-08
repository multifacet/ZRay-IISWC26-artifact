#!/usr/bin/env python3
"""Generate a text report comparing ZRay and Pin measurements.

Covers both suites the artifact measures: GAPBS and, when it has been run,
SPEC2017. Use --suite to restrict the report to one of them.

Both suites are read the same way. Counter values and byte volumes come from the
raw tool logs -- ZRay's tool_log_file.txt and the Pintool's trace CSV -- which are
written in the same format for either suite, so one pair of parsers serves both.
Reading the logs rather than the summary CSVs keeps the report unaffected by how
many times those CSVs have been appended to, and preserves the per-region and
per-function detail the CSVs discard.

Timing and peak RSS are not recorded in the logs and come from the summary CSVs,
using the last row per workload.

GAPBS logs sit beside the binaries in gapbs/ and gapbs-pin/. SPEC's live inside
the SPEC installation, one directory per workload; --spec-install says where, and
a workload whose logs cannot be found falls back to its CSV row.
"""

import argparse
import csv
import os
import sys

KERNELS = ["bc", "bfs", "cc", "cc_sv", "pr", "pr_spmv", "sssp", "tc"]

# TODO: See the note above section 4 in build_report().
INCLUDE_INSTRUMENTATION_DETAILS = False

ROI = {
    "bc": "PBFS",
    "bfs": "BUStep",
    "cc": "Link",
    "cc_sv": "ShiloachVishkin",
    "pr": "PageRankPullGS",
    "pr_spmv": "PageRankPull",
    "sssp": "RelaxEdges",
    "tc": "OrderedCount",
}

# Keys that mark the per-thread epilogue in a ZRay log (as opposed to a region body).
ZRAY_THREAD_KEYS = {
    "TOTAL HEAP LOADS",
    "TOTAL HEAP STORES",
    "TOTAL LOADS",
    "TOTAL STORES",
    "SPLIT COUNTERS",
    "TOTAL POSTPROCESS TIME",
}


def num(text):
    """Parse an integer or float counter value; return None if it isn't one."""
    try:
        return int(text)
    except ValueError:
        pass
    try:
        value = float(text)
    except ValueError:
        return None
    return value if value == value and abs(value) != float("inf") else None


def parse_zray_log(path):
    """Return per-region sums, per-thread totals, and thread count for one kernel."""
    regions = {}      # function name -> {field: summed value}
    region_times = {}  # function name -> list of per-thread TIME ELAPSED values
    totals = {}       # per-thread epilogue field -> summed value
    threads = 0
    in_epilogue = False
    func = None

    with open(path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if line.startswith("#Region"):
                in_epilogue = False
                func = None
                continue
            if ":" not in line:
                continue
            key, _, raw = line.partition(":")
            key, raw = key.strip(), raw.strip()

            if key == "Log Iteration":
                threads += 1
                in_epilogue = False
                continue
            if key == "FUNCTION":
                func = raw
                regions.setdefault(func, {})
                region_times.setdefault(func, [])
                continue
            if key in ZRAY_THREAD_KEYS and (in_epilogue or key != "SPLIT COUNTERS"):
                in_epilogue = True
                value = num(raw)
                if value is not None:
                    totals[key] = totals.get(key, 0) + value
                continue

            value = num(raw)
            if value is None or func is None:
                continue
            regions[func][key] = regions[func].get(key, 0) + value
            if key == "TIME ELAPSED (ns)":
                region_times[func].append(value)

    return {
        "regions": regions,
        "region_times": region_times,
        "totals": totals,
        "threads": threads,
    }


def parse_pin_log(path):
    """Return per-function sums, whole-run totals, and thread count for one kernel."""
    funcs = {}    # function name -> {"Reads"/"Read Bytes"/"Writes"/"Write Bytes": sum}
    totals = {}   # "Total Number of ..." -> sum
    threads = 0
    func = None

    with open(path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if line.startswith("Thread"):
                threads += 1
                func = None
                continue
            # "Function:" is the one line whose delimiter is its FIRST colon, since
            # the name that follows may itself contain "::". Take it before the
            # general case below.
            if line.startswith("Function:"):
                func = line.partition(":")[2].strip()
                funcs.setdefault(func, {})
                continue
            if ":" not in line:
                continue
            # Split on the LAST colon: a data line is "<function> <field>:<value>",
            # and C++ ROI names embed "::" (SparseMatrix<number>::vmult,
            # cMessageHeap::removeFirst, XalanDOMString::equals). Partitioning on the
            # first colon put the value into the key and silently dropped the line,
            # which zeroed the byte volumes for exactly those workloads while their
            # counts -- read from the "Total Number of" lines -- still looked right.
            key, _, raw = line.rpartition(":")
            key, raw = key.strip(), raw.strip()
            value = num(raw)
            if key.startswith("Total Number of"):
                if value is not None:
                    totals[key] = totals.get(key, 0) + value
                continue
            if func and key.startswith(func + " ") and value is not None:
                field = key[len(func) + 1:]
                funcs[func][field] = funcs[func].get(field, 0) + value

    return {"funcs": funcs, "totals": totals, "threads": threads}


def last_rows(path):
    """Map kernel name -> last row for that kernel (these CSVs append per run)."""
    if not os.path.exists(path):
        return {}
    rows = {}
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            name = (row.get("Name") or "").strip()
            if name:
                rows[name] = row
    return rows


def as_float(row, column):
    if not row:
        return None
    return num((row.get(column) or "").strip())


def pct(zray, pin):
    if zray is None or pin is None or pin == 0:
        return None
    return (zray - pin) / pin * 100.0


def fmt_int(value):
    return "-" if value is None else f"{int(value):,}"


def fmt_pct(value):
    return "-" if value is None else f"{value:+.2f}%"


def fmt_ratio(value):
    return "-" if value is None else f"{value:.2f}x"


def fmt_mb(value_kb):
    """Max RSS is collected in kB by /usr/bin/time %M; report it in MB."""
    return "-" if value_kb is None else f"{value_kb / 1024:,.1f}"


def rule(char, width):
    return char * width


# SPEC workloads, in the order the paper reports them. Names match the "Name"
# column the run scripts write, which is the SPEC benchmark name with its number
# and _r suffix stripped.
SPEC_WORKLOADS = ["perlbench", "gcc", "mcf", "namd", "parest", "povray", "lbm",
                  "omnetpp", "xalancbmk", "x264", "blender", "deepsjeng",
                  "imagick", "leela", "nab", "xz"]

# Short name -> SPEC benchmark directory, needed to locate the raw logs.
SPEC_DIRS = {
    "perlbench": "500.perlbench_r", "gcc": "502.gcc_r", "mcf": "505.mcf_r",
    "namd": "508.namd_r", "parest": "510.parest_r", "povray": "511.povray_r",
    "lbm": "519.lbm_r", "omnetpp": "520.omnetpp_r", "xalancbmk": "523.xalancbmk_r",
    "x264": "525.x264_r", "blender": "526.blender_r", "deepsjeng": "531.deepsjeng_r",
    "imagick": "538.imagick_r", "leela": "541.leela_r", "nab": "544.nab_r",
    "xz": "557.xz_r",
}

SPEC_LABEL = "zray"

# The functions actually annotated in each SPEC workload, as named by the marker
# calls in spec/roi/. Stated statically for the same reason GAPBS's ROI table is:
# it describes what was instrumented, rather than what a tool happened to observe.
# ZRay's region names cannot serve here -- they also list every function it cloned,
# which for gcc and parest runs to several hundred mangled entries.
SPEC_ROI = {
    "perlbench": "pp_and;pp_enter;pp_nextstate;pp_padsv;sha512",
    "gcc": "bitmap_bit_p;bitmap_set_bit",
    "mcf": "cost_compare;price_out_impl",
    "namd": "pairlist_from_pairlist",
    "parest": "SparseILU::vmult;SparseMatrix::vmult",
    "povray": "Check_And_Enqueue;Ray_In_Bound",
    "lbm": "LBM_performStreamCollideTRT",
    "omnetpp": "cMessageHeap::removeFirst;cSimulation::selectNextModule",
    "xalancbmk": "XalanDOMString::equals",
    "x264": "get_ref;x264_pixel_satd_8x4",
    "blender": "intersect",
    "deepsjeng": "ProbeTT",
    "imagick": "MorphologyApply",
    "leela": "merge_strings;self_atari",
    "nab": "mme34",
    "xz": "lzma_mf_bt4_find",
}


def spec_run_dir(spec_install, short_name):
    workload = SPEC_DIRS.get(short_name)
    if not workload:
        return None
    return os.path.join(spec_install, "benchspec", "CPU", workload,
                        "run", f"run_base_train_{SPEC_LABEL}-m64.0000")


def _int(value):
    return None if value is None else int(value)


def gapbs_rows(data, zray_stats, pin_stats):
    """Normalize GAPBS results, which are parsed from the raw per-thread logs."""
    rows = []
    for k in KERNELS:
        entry = data[k]
        z = entry["zray"]["totals"] if entry["zray"] else {}
        p = entry["pin"]["totals"] if entry["pin"] else {}
        zread = zwrite = None
        if entry["zray"]:
            regions = entry["zray"]["regions"].values()
            zread = sum(r.get("HEAP READ BYTES", 0) for r in regions)
            zwrite = sum(r.get("HEAP WRITTEN BYTES", 0) for r in regions)
        pread = pwrite = None
        if entry["pin"]:
            f = entry["pin"]["funcs"].get(ROI[k], {})
            pread, pwrite = f.get("Read Bytes"), f.get("Write Bytes")
        rows.append(dict(
            name=k, roi=ROI[k],
            z_loads=z.get("TOTAL HEAP LOADS"), z_stores=z.get("TOTAL HEAP STORES"),
            p_loads=p.get("Total Number of Reads"), p_stores=p.get("Total Number of Writes"),
            z_read=zread, z_write=zwrite, p_read=pread, p_write=pwrite,
            base_time=as_float(zray_stats.get(k), "Baseline Elapsed Real Time"),
            z_time=as_float(zray_stats.get(k), "Elapsed Real Time"),
            p_time=as_float(pin_stats.get(k), "Elapsed Real Time (Pin)"),
            base_rss=as_float(zray_stats.get(k), "Baseline Max RSS (kB)"),
            z_rss=as_float(zray_stats.get(k), "Max RSS (kB)"),
        ))
    return rows


def spec_rows(root, spec_install):
    """Normalize SPEC results, on the same footing as GAPBS.

    Counts and byte volumes are parsed from the raw logs with the same two
    parsers GAPBS uses -- the file formats are identical, since both suites are
    written by the same ZRay runtime and the same Pintool. Timing and RSS are not
    present in those logs and come from the summary CSVs, exactly as for GAPBS.

    The SPEC logs live inside the installation rather than the repository, so a
    workload whose logs cannot be found falls back to its CSV row.
    """
    zs = last_rows(os.path.join(root, "spec-zray-stats.csv"))
    ps = last_rows(os.path.join(root, "spec-pin-stats.csv"))
    zb = last_rows(os.path.join(root, "spec-zray-byte-stats.csv"))
    pb = last_rows(os.path.join(root, "spec-pin-byte-stats.csv"))

    rows = []
    for name in SPEC_WORKLOADS:
        if name not in zs and name not in zb:
            continue

        rd = spec_run_dir(spec_install, name)
        zray_log = os.path.join(rd, "tool_log_file.txt") if rd else None
        pin_log = os.path.join(rd, "roitrace-accum.csv") if rd else None

        z = p = None
        if zray_log and os.path.exists(zray_log):
            z = parse_zray_log(zray_log)
        if pin_log and os.path.exists(pin_log):
            p = parse_pin_log(pin_log)

        # A run interrupted before the tool wrote its results leaves an empty or
        # truncated file. Summing that yields 0, which would be reported as a real
        # measurement; treat it as missing so the row shows "-" instead.
        if z is not None and not z["regions"]:
            z = None
        if p is not None and not p["funcs"]:
            p = None

        if z:
            regions = z["regions"].values()
            z_loads = z["totals"].get("TOTAL HEAP LOADS")
            z_stores = z["totals"].get("TOTAL HEAP STORES")
            z_read = sum(r.get("HEAP READ BYTES", 0) for r in regions)
            z_write = sum(r.get("HEAP WRITTEN BYTES", 0) for r in regions)
            roi = None      # named from Pin's markers below
        else:
            z_loads = _int(as_float(zs.get(name), "Total Heap Loads"))
            z_stores = _int(as_float(zs.get(name), "Total Heap Stores"))
            z_read = _int(as_float(zb.get(name), "Read Bytes"))
            z_write = _int(as_float(zb.get(name), "Written Bytes"))
            roi = SPEC_ROI.get(name, "-")

        if p:
            funcs = p["funcs"].values()
            p_loads = p["totals"].get("Total Number of Reads")
            p_stores = p["totals"].get("Total Number of Writes")
            p_read = sum(f.get("Read Bytes", 0) for f in funcs)
            p_write = sum(f.get("Write Bytes", 0) for f in funcs)
        else:
            p_loads = _int(as_float(ps.get(name), "Total Loads"))
            p_stores = _int(as_float(ps.get(name), "Total Stores"))
            p_read = _int(as_float(pb.get(name), "Read Bytes"))
            p_write = _int(as_float(pb.get(name), "Written Bytes"))

        if roi is None:
            roi = SPEC_ROI.get(name, "-")

        rows.append(dict(
            name=name, roi=roi,
            z_loads=z_loads, z_stores=z_stores,
            p_loads=p_loads, p_stores=p_stores,
            z_read=z_read, z_write=z_write, p_read=p_read, p_write=p_write,
            base_time=as_float(zs.get(name), "Baseline Elapsed Real Time"),
            z_time=as_float(zs.get(name), "Elapsed Real Time"),
            p_time=as_float(ps.get(name), "Elapsed Real Time (Pin)"),
            base_rss=as_float(zs.get(name), "Baseline Max RSS (kB)"),
            z_rss=as_float(zs.get(name), "Max RSS (kB)"),
        ))
    return rows


def build_report(root, suite="all", spec_install=None):
    spec_install = spec_install or os.environ.get(
        "SPEC_INSTALL", os.path.join(root, "spec2017"))
    zray_dir = os.path.join(root, "gapbs")
    pin_dir = os.path.join(root, "gapbs-pin")

    zray_stats = last_rows(os.path.join(zray_dir, "zray-gapbs-stats.csv"))
    pin_stats = last_rows(os.path.join(pin_dir, "pin-gapbs-stats.csv"))

    data = {}
    missing = []
    # Only read the GAPBS raw logs when GAPBS is actually being reported, so that
    # --suite spec does not warn about logs it has no use for.
    if suite in ("gapbs", "all"):
        for kernel in KERNELS:
            zray_log = os.path.join(zray_dir, kernel, "tool_log_file.txt")
            pin_log = os.path.join(pin_dir, kernel, "roitrace-mt.csv")
            entry = {"zray": None, "pin": None}
            if os.path.exists(zray_log):
                entry["zray"] = parse_zray_log(zray_log)
            else:
                missing.append(zray_log)
            if os.path.exists(pin_log):
                entry["pin"] = parse_pin_log(pin_log)
            else:
                missing.append(pin_log)
            data[kernel] = entry

    # Suites are reported in the same order, and under the same three sections,
    # as the paper's figures put them on one axis.
    suites = []
    if suite in ("gapbs", "all"):
        suites.append(("GAPBS", gapbs_rows(data, zray_stats, pin_stats)))
    if suite in ("spec", "all"):
        srows = spec_rows(root, spec_install)
        if srows:
            suites.append(("SPEC2017", srows))
    multi = len(suites) > 1

    out = []
    w = 100
    out.append(rule("=", w))
    title = " and ".join(n for n, _ in suites) or "no suites"
    out.append(f"ZRay vs. Intel Pin - {title} measurement comparison")
    out.append(rule("=", w))
    out.append("")
    out.append(f"Artifact root : {os.path.abspath(root)}")
    if data:
        zthreads = {k: v["zray"]["threads"] for k, v in data.items() if v["zray"]}
        pthreads = {k: v["pin"]["threads"] for k, v in data.items() if v["pin"]}
        out.append(f"ZRay threads  : {sorted(set(zthreads.values())) or '-'} (GAPBS per-thread log blocks)")
        out.append(f"Pin threads   : {sorted(set(pthreads.values())) or '-'} (GAPBS per-thread trace blocks)")
    if missing:
        out.append("")
        out.append("WARNING - missing raw logs (those kernels are reported as '-'):")
        for path in missing:
            out.append(f"  {path}")
    out.append("")

    # ---- Section 1: heap access counts -------------------------------------
    out.append(rule("-", w))
    out.append("1. HEAP ACCESS COUNTS  (ZRay heap loads/stores vs. Pin non-RSP loads/stores)")
    out.append(rule("-", w))
    out.append("")
    header = f"{'Workload':<11}{'Metric':<9}{'ZRay':>19}{'Pin':>19}{'Delta':>19}{'Diff':>12}"
    out.append(header)
    out.append(rule(".", w))

    checks = []
    sec1 = []
    for suite_name, rows in suites:
        if multi:
            out.append(f"{suite_name}")
        for r in rows:
            pairs = [
                ("loads", r["z_loads"], r["p_loads"]),
                ("stores", r["z_stores"], r["p_stores"]),
            ]
            for label, zval, pval in pairs:
                d = pct(zval, pval)
                delta = None if zval is None or pval is None else zval - pval
                if d is not None:
                    checks.append((r["name"], f"heap {label}", d))
                    sec1.append(d)
                out.append(
                    f"{r['name'] if label == 'loads' else '':<11}{label:<9}"
                    f"{fmt_int(zval):>19}{fmt_int(pval):>19}{fmt_int(delta):>19}"
                    f"{fmt_pct(d):>12}"
                )
            out.append("")
    out.append(rule(".", w))
    if sec1:
        out.append(f"  mean difference : {sum(sec1) / len(sec1):+.2f}%")
    out.append("")

    # ---- Section 2: ROI byte volumes --------------------------------------
    out.append(rule("-", w))
    out.append("2. ROI HEAP BYTE VOLUMES  (bytes moved inside the instrumented hot function)")
    out.append(rule("-", w))
    out.append("")
    out.append(header)
    out.append(rule(".", w))

    sec2 = []
    for suite_name, rows in suites:
        if multi:
            out.append(f"{suite_name}")
        for r in rows:
            pairs = [("read B", r["z_read"], r["p_read"]),
                     ("write B", r["z_write"], r["p_write"])]
            for label, zval, pval in pairs:
                d = pct(zval, pval)
                delta = None if zval is None or pval is None else zval - pval
                if d is not None:
                    checks.append((r["name"], f"ROI {label.strip()}", d))
                    sec2.append(d)
                out.append(
                    f"{r['name'] if label == 'read B' else '':<11}{label:<9}"
                    f"{fmt_int(zval):>19}{fmt_int(pval):>19}{fmt_int(delta):>19}"
                    f"{fmt_pct(d):>12}"
                )
            # A SPEC workload may mark several functions; they are summed into one
            # row, so the ROI line lists all of them.
            out.append(f"{'':<11}{'ROI':<9}{r['roi']}")
            out.append("")
    out.append(rule(".", w))
    if sec2:
        out.append(f"  mean difference : {sum(sec2) / len(sec2):+.2f}%")
    out.append("")

    # ---- Section 3: runtime and memory ------------------------------------
    out.append(rule("-", w))
    out.append("3. RUNTIME AND MEMORY")
    out.append(rule("-", w))
    out.append("")
    out.append(
        f"{'Workload':<11}{'Control (s)':>12}{'ZRay (s)':>12}{'ZRay x':>10}"
        f"{'Pin (s)':>12}{'Pin x':>10}"
    )
    out.append(rule(".", w))
    zray_slow, pin_slow = [], []
    mem_rows = []
    for suite_name, rows in suites:
        if multi:
            out.append(f"{suite_name}")
        for r in rows:
            # One control for both tools: the uninstrumented build measured in the
            # same run as ZRay. The Pin scripts' own uninstrumented run is only a
            # page-cache warm-up and is not used as a denominator.
            zbase, ztime, ptime = r["base_time"], r["z_time"], r["p_time"]
            zr = ztime / zbase if ztime and zbase else None
            pr = ptime / zbase if ptime and zbase else None
            if zr:
                zray_slow.append(zr)
            if pr:
                pin_slow.append(pr)
            f2 = lambda v: "-" if v is None else f"{v:.2f}"
            out.append(
                f"{r['name']:<11}{f2(zbase):>12}{f2(ztime):>12}{fmt_ratio(zr):>10}"
                f"{f2(ptime):>12}{fmt_ratio(pr):>10}"
            )
            mem_rows.append((r["name"], r["base_rss"], r["z_rss"], None))
    out.append(rule(".", w))
    if zray_slow:
        out.append(f"  mean ZRay slowdown vs. native: {sum(zray_slow) / len(zray_slow):.2f}x")
    if pin_slow:
        out.append(f"  mean Pin  slowdown vs. native: {sum(pin_slow) / len(pin_slow):.2f}x")
    out.append("")
    #out.append("  Control is the uninstrumented gapbs/ build, and normalizes both tools. ZRay is")
    #out.append("  timed in the same run as the control; Pin is timed by run-gapbs-pin.sh separately, so")
    #out.append("  Pin x also carries whatever machine drift lies between the two runs.")
    #out.append("")
    #out.append("  Peak resident set size, and overhead relative to the uninstrumented baseline:")
    #out.append("")
    out.append(
        f"{'Workload':<11}{'Control MB':>12}{'ZRay MB':>13}{'ZRay +MB':>11}{'ZRay +%':>10}"
    )
    out.append(rule(".", w))
    zray_mem = []
    for kernel, base, zrss, pctl in mem_rows:
        zo = (zrss - base) / base * 100 if zrss and base else None
        if zo is not None:
            zray_mem.append(zo)
        zd = f"{(zrss - base) / 1024:+,.1f}" if zrss and base else "-"
        out.append(
            f"{kernel:<11}{fmt_mb(base):>12}{fmt_mb(zrss):>13}{zd:>11}"
            f"{('-' if zo is None else f'{zo:+.3f}%'):>10}"
        )
    out.append(rule(".", w))
    if zray_mem:
        out.append(f"  mean ZRay RSS overhead: {sum(zray_mem) / len(zray_mem):+.3f}%")
    out.append("")
    #out.append("  ZRay's RSS cost is near-constant in absolute terms, so it shrinks as a share of")
    #out.append("  larger footprints.")
    #out.append("")

    # ---- Section 4: ZRay instrumentation details ---------------------------
    # TODO: Decide whether to keep this section. Disabled to keep the report short;
    # set INCLUDE_INSTRUMENTATION_DETAILS back to True to restore it, or delete the
    # block if we settle on leaving it out.
    if INCLUDE_INSTRUMENTATION_DETAILS:
        out.append(rule("-", w))
        out.append("4. ZRAY INSTRUMENTATION DETAILS")
        out.append(rule("-", w))
        out.append("")
        out.append(
            f"{'Kernel':<9}{'Total ld':>18}{'Total st':>16}{'Stack ld':>16}"
            f"{'Stack st':>16}{'Total inst':>22}{'Cntr inst':>22}"
        )
        out.append(rule(".", 119))
        for kernel in KERNELS:
            entry = data[kernel]
            if not entry["zray"]:
                out.append(f"{kernel:<9}{'-':>18}")
                continue
            t = entry["zray"]["totals"]
            regions = entry["zray"]["regions"].values()
            agg = lambda key: sum(r.get(key, 0) for r in regions)
            out.append(
                f"{kernel:<9}{fmt_int(t.get('TOTAL LOADS')):>18}"
                f"{fmt_int(t.get('TOTAL STORES')):>16}"
                f"{fmt_int(agg('STACK R')):>16}{fmt_int(agg('STACK W')):>16}"
                f"{fmt_int(agg('TOTAL INST')):>22}{fmt_int(agg('COUNTER INST')):>22}"
            )
        out.append("")
        out.append("  Instrumentation cost (ZRay counters), and ROI wall-clock behaviour:")
        out.append("")
        out.append(
            f"{'Kernel':<9}{'Cntr/app inst':>16}{'Overhead incr':>18}"
            f"{'Thread-ns sum':>20}{'Max thread ns':>18}{'Regions':>10}"
        )
        out.append(rule(".", w))
        for kernel in KERNELS:
            entry = data[kernel]
            if not entry["zray"]:
                out.append(f"{kernel:<9}{'-':>16}")
                continue
            regions = entry["zray"]["regions"].values()
            agg = lambda key: sum(r.get(key, 0) for r in regions)
            total_inst, cntr_inst = agg("TOTAL INST"), agg("COUNTER INST")
            ratio = cntr_inst / total_inst if total_inst else None
            tsum = agg("TIME ELAPSED (ns)")
            tmax = max(
                (max(v) for v in entry["zray"]["region_times"].values() if v), default=None
            )
            out.append(
                f"{kernel:<9}{'-' if ratio is None else f'{ratio:.2f}':>16}"
                f"{fmt_int(agg('OVERHEAD INCREMENTS')):>18}"
                f"{fmt_int(tsum):>20}{fmt_int(tmax):>18}"
                f"{len(entry['zray']['regions']):>10}"
            )
        out.append("")
        out.append("  Legend")
        out.append("    Total ld/st     Load and store instructions executed in the instrumented")
        out.append("                    regions, summed over all threads.")
        out.append("    Stack ld/st     The subset of those whose target was on the stack. Heap")
        out.append("                    accesses are Total minus Stack, and are what Pin is compared")
        out.append("                    against in section 1.")
        out.append("    Total inst      All instructions executed in the regions: the application's")
        out.append("                    own work, excluding ZRay's added counter code.")
        out.append("    Cntr inst       Instructions ZRay added to maintain its counters. Directly")
        out.append("                    comparable to Total inst above.")
        out.append("    Cntr/app inst   Cntr inst divided by Total inst. 1.00 means ZRay emitted one")
        out.append("                    instruction of bookkeeping per application instruction. This")
        out.append("                    is a static code-volume ratio, not a slowdown: see section 3")
        out.append("                    for measured wall-clock cost.")
        out.append("    Overhead incr   Counter increments that ZRay's own analysis attributes to")
        out.append("                    instrumentation overhead rather than to application behaviour.")
        out.append("    Thread-ns sum   Time inside the regions summed across every thread, in")
        out.append("                    nanoseconds. With N threads busy this is roughly N times the")
        out.append("                    wall-clock time, so it is thread-nanoseconds, not elapsed time.")
        out.append("    Max thread ns   The largest single thread's time in the regions. This is the")
        out.append("                    figure that corresponds to elapsed wall-clock time.")
        out.append("    Regions         Number of distinct instrumented regions ZRay recorded. Exceeds")
        out.append("                    one when OpenMP outlines a region into several functions.")
        out.append("")

    # ---- Section 5: verdict ------------------------------------------------
    #out.append(rule("-", w))
    #out.append("4. SUMMARY")
    #out.append(rule("-", w))
    #out.append("")
    #if not checks:
    #    out.append("  No comparable metrics were found - check that both workflows have been run.")
    #else:
    #    worst = sorted(checks, key=lambda c: -abs(c[2]))
    #    out.append(f"  Comparisons made : {len(checks)}")
    #    out.append(f"  Mean difference  : {sum(c[2] for c in checks) / len(checks):+.2f}%")
    #    out.append("")
    #    out.append("  Largest deviations:")
    #    for kernel, metric, d in worst[:5]:
    #        out.append(f"    {kernel:<9}{metric:<14}{fmt_pct(d):>10}")
    #    out.append("")
    #    exact = sorted({k for k, _, d in checks if abs(d) < 0.001})
    #    out.append(f"  Bit-exact agreement     : {', '.join(exact) if exact else 'none'}")
    #    out.append("")
    #    out.append("  ZRay never counts more than Pin; all disagreement is under-counting, from two")
    #    out.append("  causes:")
    #    out.append("")
    #    out.append("  (a) Memory intrinsics. ZRay adds memcpy/memmove/memset traffic to the BYTE")
    #    out.append("      totals in full but derives an access COUNT as bytes/8 (zray_dyn.cc:699).")
    #    out.append("      Pin counts once per REP iteration, and glibc lowers these to 'rep movsb'")
    #    out.append("      on an ERMS CPU, so it logs ~1 write per byte copied (roitrace-mt.cpp:223).")
    #    out.append("      Neither is the retired store count. Compare bytes, not counts.")
    #    out.append("  (b) Scheduling. The two are separate runs of separately built binaries, so")
    #    out.append("      schedule-dependent kernels genuinely differ.")
    #    out.append("")
    #    out.append(f"{'Kernel':<9}{'Intrinsic ld B':>18}{'Intrinsic st B':>18}"
    #               f"{'ZRay B/store':>15}{'Pin B/store':>14}")
    #    out.append(rule(".", w))
    #    for kernel in KERNELS:
    #        entry = data[kernel]
    #        if not (entry["zray"] and entry["pin"]):
    #            continue
    #        regions = entry["zray"]["regions"].values()
    #        agg = lambda key: sum(r.get(key, 0) for r in regions)
    #        zst = entry["zray"]["totals"].get("TOTAL HEAP STORES") or 0
    #        zwb = agg("HEAP WRITTEN BYTES")
    #        f = entry["pin"]["funcs"].get(ROI[kernel], {})
    #        pst, pwb = f.get("Writes") or 0, f.get("Write Bytes") or 0
    #        out.append(
    #            f"{kernel:<9}{fmt_int(agg('INTRINSIC LOAD')):>18}"
    #            f"{fmt_int(agg('INTRINSIC STORE')):>18}"
    #            f"{(f'{zwb / zst:.2f}' if zst else '-'):>15}"
    #            f"{(f'{pwb / pst:.2f}' if pst else '-'):>14}"
    #        )
    #out.append("")

    out.append(rule("=", w))
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.path.dirname(os.path.abspath(__file__)),
                        help="artifact root containing gapbs/ and gapbs-pin/")
    parser.add_argument("-o", "--out", help="write the report to this file as well as stdout")
    parser.add_argument("--suite", choices=["gapbs", "spec", "all"], default="all",
                        help="which benchmark suites to report (default: all present)")
    parser.add_argument("--spec-install", default=None,
                        help="SPEC installation holding the raw logs (default: ./spec2017)")
    args = parser.parse_args()

    report = build_report(args.root, args.suite, args.spec_install)
    print(report)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(report + "\n")
        print(f"\nWrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
