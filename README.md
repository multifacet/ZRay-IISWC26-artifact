# ZRay IISWC'26 Artifact

This repository provides an automated way to build ZRay and run the GAP Benchmark
Suite (GAPBS) and SPEC CPU2017 experiments used for artifact evaluation and for
verifying ZRay's functionality.

## Requirements

- Ubuntu 22.04
- At least 80 GB of free storage. The GAPBS Twitter graphs account for most of it (31 GB downloaded, 44 GB converted). The optional SPEC CPU2017 workflow needs a further 10 GB once built, plus about 3 GB transiently while the ISO is unpacked.
- `sudo` access and an Internet connection during setup

We recommend using a CloudLab `sm110p` or `sm220u` node and selecting the maximum
available tempfs partition. The default ZRay workflow is portable to other
architectures supported by LLVM 15. The optional Pin validation workflow requires
an Intel x86-64 machine.

The scripts do not set `OMP_NUM_THREADS`; they use the OpenMP configuration chosen
by the user. Runtime and memory-use results therefore depend on the selected
hardware and thread count.

## At a glance

Set the machine up once, then run whichever suites you want. Each run script
builds whatever it needs on first use, so there is no separate build step.

```bash
./setup.sh --with-pin --with-spec --spec-path=/path/to/spec2017.iso

./run-gapbs.sh        # GAPBS: control + ZRay
./run-gapbs-pin.sh    # GAPBS: Pin
./run-spec.sh         # SPEC:  control + ZRay   (builds on first run, ~50 min)
./run-spec-pin.sh     # SPEC:  Pin

python3 compare-zray-pin.py -o report.txt
```

Both `--with` flags are optional; without them you get the ZRay GAPBS workflow
alone.

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

This downloads Pin 4.3 and builds the Pintool and the separate `gapbs-pin/`
workloads. It does not generate a second set of graphs: `gapbs-pin/benchmark/graphs`
is symlinked to the copy under `gapbs/`, since both trees run the same converter
over the same input and the kernels only read the result. The paper's experiments used Pin 3.31; the
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

Neither tool instruments the entire workload. In each GAPBS kernel exactly one
function is annotated, and ZRay and Pin are annotated at the same source locations.
SPEC differs: several of its workloads annotate two or three functions, which are
summed into one reported row.

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
./run-gapbs-pin.sh
```

This runs the GAPBS workloads with the Pintool attached, collects the measurements,
and produces CSV summaries in `gapbs-pin/`:

- `pin-gapbs-stats.csv`
- `pin-byte-stats.csv`

Compare `Read Bytes` and `Written Bytes` in `pin-byte-stats.csv` with the matching
columns in `zray-byte-stats.csv`. The load/store totals use the paper's operational
definition of heap accesses: the Pintool excludes RSP-based stack accesses, while
ZRay reports dedicated heap load/store columns in `zray-gapbs-stats.csv`.

Load and store counts may differ between ZRay and Pin while byte counts remain
accurate. This is because the two tools attribute bulk copies differently: a
`memcpy`/`memmove` is
a single IR instruction to ZRay, which records its byte length and estimates an access
count from it, while Pin counts the machine-level accesses the lowered copy performs.
In `sssp`, whose `RelaxEdges` region resizes and appends to `std::vector`, this makes
the two store *counts* differ by roughly 2x even though the byte totals agree to within
2%. Kernels with no bulk-copy traffic agree on both.

## SPEC CPU2017

SPEC CPU2017 is licensed and cannot be distributed with this artifact. Only release **CPU2017v1.0.2** is supported: the ROI markers ship as
line-numbered patches guarded by checksums, and setup refuses any other release
rather than risk placing markers in the wrong place.

```bash
./setup.sh --with-spec --spec-path=/path/to/spec2017.iso
```

This installs SPEC into `spec2017/` (override with `--spec-install=PATH`; the tree
reaches about 10 GB once the workloads are built). It does not build the workloads: `./run-spec.sh` does that on
its first invocation, taking about 50 minutes to build each workload three times -
control, ZRay, and Pin - and staging the binaries into the run directories.
Subsequent runs detect the existing binaries and skip straight to measuring; pass
`FORCE_BUILD=1` to rebuild. Add `--with-pin` to perform the Pin
comparison; the two flags compose, and without it only the control and ZRay
variants are built.

Then run:

```bash
./run-spec.sh        # control and ZRay
./run-spec-pin.sh    # Pin, optional
```

These write `spec-zray-stats.csv`, `spec-zray-byte-stats.csv`,
`spec-pin-stats.csv`, and `spec-pin-byte-stats.csv` in the repository root, and the
comparison report picks them up automatically.

The 16 workloads are those written exclusively in C or C++, run on **train** inputs at `-O2`.

Two benchmarks need a portability flag with clang 15, both applied through the
generated SPEC config so all three variants are built identically:

- `502.gcc_r` uses `-fgnu89-inline`. At `-O2` glibc emits an `extern inline`
  definition of `vprintf` in every translation unit; SPEC tolerates the duplicates
  with `-z muldefs`, but this artifact links the IR with `llvm-link` first, which
  does not.
- `510.parest_r` uses `-std=gnu++98`. It compares a pointer against `'\0'`, which
  was a null pointer constant in C++03 but is an error under C++11 and later.

## Comparison report

To generate a text report of the results, run:

```bash
python3 compare-zray-pin.py
```

This prints the report to stdout; pass `-o report.txt` to also write it to a file,
and `--suite {gapbs,spec,all}` to restrict it to one suite. Both suites appear under
the same three sections, grouped by suite:

1. **Heap access counts** - ZRay heap loads/stores against Pin's non-RSP loads/stores,
   with the difference per kernel.
2. **ROI heap byte volumes** - bytes read and written inside each instrumented function.
3. **Runtime and memory** - ZRay and Pin each normalized against that suite's
   uninstrumented control, plus peak RSS and ZRay's memory overhead.

Both suites are read the same way. Access counts and byte volumes come from the raw
tool logs - ZRay's `tool_log_file.txt` and the Pintool's trace CSV - which share a
format across suites, so one pair of parsers serves both.
Timing and peak RSS are not in the logs and come from the CSVs,
using the last row per workload.

GAPBS logs sit beside the binaries in `gapbs/` and `gapbs-pin/`. SPEC's live inside
the SPEC installation; pass `--spec-install=PATH` if it is not `./spec2017`. A
workload whose logs cannot be found falls back to its CSV row.

Run `./run-gapbs.sh` first. The Pin scripts are optional: without them the Pin columns
are reported as `-` and the ZRay measurements are still shown. Likewise, SPEC rows
appear only once `./run-spec.sh` has been run.

## Re-running experiments

All four run scripts are safe to re-run. `run-gapbs.sh` removes `zray-gapbs-stats.csv`
and `run-gapbs-pin.sh` removes `pin-gapbs-stats.csv` and `pin-byte-stats.csv` before
collecting, so results reflect a single run rather than accumulating across runs. The
remaining GAPBS summary CSVs are truncated by the coalesce scripts that write them.

The SPEC scripts behave the same way for a full run. Given explicit workload arguments
they append instead, so re-measuring one workload cannot discard the other fifteen -
the report reads the last row per workload, so an appended correction supersedes the
earlier value:

```bash
./run-spec.sh 505.mcf_r      # re-measure just mcf, keeping every other row
```

The scripts do not interfere with each other: each touches only its own suite's
directories and CSVs, so a Pin run leaves the ZRay results and the uninstrumented
control intact, and vice versa.

Re-running a SPEC script does not rebuild. Pass `FORCE_BUILD=1` to force that.

## Licenses

ZRay and the custom Pintool source are released under the MIT License. Each GAPBS
copy retains its included BSD 3-Clause license. Intel Pin is downloaded during the
optional setup step and is subject to Intel's license terms.
