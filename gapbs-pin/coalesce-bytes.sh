#!/bin/bash

if [ ! -f ./pin-byte-stats.csv ]; then
    echo "Name,Function,Read Bytes,Written Bytes" >> pin-byte-stats.csv
fi

kernels=("bc" "bfs" "cc" "cc_sv" "pr" "pr_spmv" "sssp" "tc")

functions=("PBFS" "BUStep" "Link" "ShiloachVishkin" "PageRankPullGS" "PageRankPull" "RelaxEdges" "OrderedCount")

BASE_DIR=$(pwd)

for i in $(seq 0 7); do
    cd $BASE_DIR
    cd ${kernels[$i]}
    READ_BYTES=$(grep "Read Bytes" roitrace-mt.csv | grep -o '\w*$' | paste -sd+ - | bc)
    WRITE_BYTES=$(grep "Write Bytes" roitrace-mt.csv | grep -o '\w*$' | paste -sd+ - | bc)
    echo ${kernels[$i]},${functions[$i]},$READ_BYTES,$WRITE_BYTES>> ../pin-byte-stats.csv
done
