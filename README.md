# ZRay IISWC'26 Artifact

This repository provides an automated way to build ZRay and run the GAP Benchmark
Suite (GAPBS) experiments used for artifact evaluation and verifying ZRay's functionality.

## Requirements

- Ubuntu 22.04
- At least 75 GB for validating ZRay's functionality by itself, or at least
  150 GB of free storage for the complete ZRay and Pin workflows, which
  each build their own representations of the GAPBS Twitter graphs
- `sudo` access and an Internet connection during setup

We recommend using a CloudLab `sm110p` or `sm220u` node and selecting the maximum
available tempfs partition. The default ZRay workflow is portable to other
architectures supported by LLVM 15. The optional Pin validation workflow requires
an Intel x86-64 machine.

The scripts do not set `OMP_NUM_THREADS`; they use the OpenMP configuration chosen
by the user. Runtime and memory-use results therefore depend on the selected
hardware and thread count.

## Setup

From the repository root, run:

```bash
./setup.sh
```

This installs the required dependencies, builds ZRay and the ZRay-instrumented
GAPBS workloads, generates the required Twitter graphs, and installs the Python
packages used to summarize the results.

To additionally set up the optional Pin comparison workflow, run:

```bash
./setup.sh --with-pin
```

This downloads Pin 4.3, builds the Pintool and the separate `gapbs-pin/` workloads,
and generates their graph files. The paper's experiments used Pin 3.31; the
included Pintool has also been verified with the Pin 4.3 package downloaded here.

## Run the experiments

After the default setup completes, run:

```bash
./run-gapbs.sh
```

This runs the GAPBS workloads with ZRay, collects the measurements, and produces CSV
summaries in `gapbs/`:

- `zray-gapbs-stats.csv`
- `zray-byte-stats.csv`
- `zray-gapbs-bandwidth-stats.csv`

Each workload is run three times: a discarded warm-up, then the uninstrumented control,
then the ZRay-instrumented binary. The uninstrumented build comes from the same sources
through the same optimization pipeline, minus the ZRay pass. The warm-up exists because
reading the graph takes several seconds and is not instrumented by either build, so an
unequal page cache state between the two measured runs would appear as instrumentation
overhead. The two measured
times and peak RSS values land
in `zray-gapbs-stats.csv` as `Elapsed Real Time` / `Max RSS (kB)` and
`Baseline Elapsed Real Time` / `Baseline Max RSS (kB)`. Compare those two pairs to get
ZRay's runtime and memory overhead.

`pin-gapbs-stats.csv` also records a `Warmup Elapsed Real Time`, but that run exists
only to warm the page cache before the Pin run.
Do not use it as a control; both tools are normalized against the
uninstrumented `gapbs/` build described above.

## What is instrumented

Neither tool instruments the entire workload. In each kernel, exactly one function is
annotated, and ZRay and Pin are annotated at the same source locations:

| Workload  | Instrumented function | Coverage                                        |
| --------- | --------------------- | ----------------------------------------------- |
| `bc`      | `PBFS`                | subset - the `omp parallel` region              |
| `bfs`     | `BUStep`              | subset - the `omp parallel for` body            |
| `cc`      | `Link`                | entire function body                            |
| `cc_sv`   | `ShiloachVishkin`     | subset - the three `omp parallel for` bodies    |
| `pr`      | `PageRankPullGS`      | subset - the two `omp parallel for` bodies      |
| `pr_spmv` | `PageRankPull`        | subset - the main `omp parallel for` body       |
| `sssp`    | `RelaxEdges`          | entire function body                            |
| `tc`      | `OrderedCount`        | subset - the `omp parallel for` body            |

Only `cc` and `sssp` cover an entire function. In the other six the markers sit inside
the function, around the parallel loop, so surrounding setup, reductions, and return
statements are outside the measured region. Graph loading, graph construction, and
result verification are outside the measured region in every workload.

ZRay is marked with `asm volatile("#ZRAY_ROI_BEGIN 1")` / `#ZRAY_ROI_END`, which an
LLVM pass replaces with counter instrumentation at compile time. Pin is marked with
`custom_roi_begin()` / `custom_roi_end()`, empty functions the Pintool detects at
runtime to toggle a per-thread tracing flag.

## Pintool validation

After completing `./setup.sh --with-pin` on an Intel x86-64 machine, run:

```bash
./run-pin.sh
```

This runs the GAPBS workloads with the Pintool attached, collects the measurements,
and produces CSV summaries in `gapbs-pin/`:

- `pin-gapbs-stats.csv`
- `pin-byte-stats.csv`

Compare `Read Bytes` and `Written Bytes` in `pin-byte-stats.csv` with the matching
columns in `zray-byte-stats.csv`. The load/store totals use the paper's operational
definition of heap accesses: the Pintool excludes RSP-based stack accesses, while
ZRay reports dedicated heap load/store columns in `zray-gapbs-stats.csv`.

Instruction counts may differ between ZRay and Pin while byte counts remain accurate. This is because the two tools attribute bulk copies differently: a `memcpy`/`memmove` is
a single IR instruction to ZRay, which records its byte length and estimates an access
count from it, while Pin counts the machine-level accesses the lowered copy performs.
In `sssp`, whose `RelaxEdges` region resizes and appends to `std::vector`, this makes
the two store *counts* differ by roughly 2x even though the byte totals agree to within
2%. Kernels with no bulk-copy traffic agree on both.

The artifact validates the eight GAPBS kernels used by these scripts on the Twitter
graph; it does not reproduce the full GAPBS+SPEC evaluation in the paper.

## Comparison report

To generate a text report of the results, run:

```bash
python3 compare-zray-pin.py
```

This prints the report to stdout; pass `-o report.txt` to also write it to a file.
It emits three sections:

1. **Heap access counts** - ZRay heap loads/stores against Pin's non-RSP loads/stores,
   with the difference per kernel.
2. **ROI heap byte volumes** - bytes read and written inside each instrumented function.
3. **Runtime and memory** - ZRay and Pin each normalized against the uninstrumented
   `gapbs/` control, plus peak RSS and ZRay's memory overhead.

Access counts and byte volumes are parsed from the raw per-thread logs
(`gapbs/<kernel>/tool_log_file.txt` and `gapbs-pin/<kernel>/roitrace-mt.csv`) rather
than the summary CSVs, so they are unaffected by how many times those CSVs have been
appended to. Timing and RSS come from the CSVs, using the last row for each kernel.

Run `./run-gapbs.sh` first. `./run-pin.sh` is optional: without it the Pin columns are
reported as `-` and the ZRay measurements are still shown.

## Re-running experiments

Both scripts are safe to re-run. `run-gapbs.sh` removes `zray-gapbs-stats.csv` and
`run-pin.sh` removes `pin-gapbs-stats.csv` and `pin-byte-stats.csv` before collecting,
so results reflect a single run rather than accumulating across runs. The remaining
summary CSVs are truncated by the coalesce scripts that write them.

The two scripts do not interfere: `run-pin.sh` touches only `gapbs-pin/`, so the ZRay
results and the uninstrumented baseline in `gapbs/` survive a Pin run, and vice versa.

To accumulate rows across runs deliberately, comment out the `rm -f` lines at the top
of the relevant script.

## Licenses

ZRay and the custom Pintool source are released under the MIT License. Each GAPBS
copy retains its included BSD 3-Clause license. Intel Pin is downloaded during the
optional setup step and is subject to Intel's license terms.
