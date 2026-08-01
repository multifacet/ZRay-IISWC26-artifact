#!/bin/bash

echo "Name,Function,Time Elapsed (ns),Max Thread Time Elapsed,Read Bytes,Written Bytes,Total Instructions,Counter Instructions,Counter Increments Contributing to Overhead" > zray-byte-stats.csv

kernels=("bc" "bfs" "cc" "cc_sv" "pr" "pr_spmv" "sssp" "tc")

functions=("PBFS" "BUStep" "Link" "ShiloachVishkin" "PageRankPullGS" "PageRankPull" "RelaxEdges" "OrderedCount")

BASE_DIR=$(pwd)

for i in $(seq 0 7); do
    cd $BASE_DIR
    cd ${kernels[$i]}
    TIME_ELAPSED=$(grep "TIME ELAPSED (ns)" tool_log_file.txt | grep -o '\w*$' | paste -sd+ - | bc)
    MAX_THREAD_TIME=$(grep "TIME ELAPSED (ns)" tool_log_file.txt | grep -o '\w*$' | sort -n | tail -1)
    READ_BYTES=$(grep "HEAP READ BYTES" tool_log_file.txt | grep -o '\w*$' | paste -sd+ - | bc)
    WRITE_BYTES=$(grep "HEAP WRITTEN BYTES" tool_log_file.txt | grep -o '\w*$' | paste -sd+ - | bc)
    TOTAL_INST=$(grep "TOTAL INST" tool_log_file.txt | grep -o '\w*$' | paste -sd+ - | bc)
    CNTR_INST=$(grep "COUNTER INST" tool_log_file.txt | grep -o '\w*$' | paste -sd+ - | bc)
    OVERHEAD=$(grep "OVERHEAD INCREMENTS" tool_log_file.txt | grep -o '\w*$' | paste -sd+ - | bc)
    echo ${kernels[$i]},${functions[$i]},$TIME_ELAPSED,$MAX_THREAD_TIME,$READ_BYTES,$WRITE_BYTES,$TOTAL_INST,$CNTR_INST,$OVERHEAD >> ../zray-byte-stats.csv
done
