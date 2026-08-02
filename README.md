# ZRay IISWC'26 Artifact

This repository provides an automated way to build ZRay and run the GAP Benchmark
Suite (GAPBS) experiments used for artifact evaluation and verifying ZRay's functionality.

## Requirements

- Ubuntu 22.04
- At least 150 GB of free storage for the different representations of the GAPBS
  Twitter graphs
- `sudo` access and an Internet connection during setup

We recommend using a CloudLab `sm110p` or `sm220u` node and selecting the maximum
available tempfs partition. Other CloudLab node types should also work, including
nodes with non-x86 architectures for the ZRay experiments. Pin requires an Intel server.

## Setup

From the repository root, run:

```bash
./setup.sh
```

This installs the required dependencies, builds ZRay and GAPBS, generates the GAPBS
benchmark graphs, and installs the Python packages used to summarize the results.

## Run the experiments

After setup completes, run:

```bash
./run-gapbs.sh
```

This runs the GAPBS workloads with ZRay, collects the measurements, and produces CSV
summaries in `gapbs/`:

- `zray-gapbs-stats.csv`
- `zray-byte-stats.csv`
- `zray-gapbs-bandwidth-stats.csv`

## Pintool validation

After setup completes, run:

```bash
./run-pin.sh
```

This runs the GAPBS workloads with the pintool attached, collects the measurements, and produces CSV
summaries in `gapbs-pin/`:

- `pin-gapbs-stats.csv`
- `pin-byte-stats.csv`

These measurements can be compared against the csv data obtained after running the workloads with ZRay.

For details about ZRay itself, see [`ZRay/readme.md`](ZRay/readme.md).
