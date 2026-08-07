#!/bin/bash

if [ ! -f ./zray-gapbs-stats.csv ]; then
	echo "Name,Total Loads,Total Stores,Total Heap Loads,Total Heap Stores,Total Instruction Count,Elapsed Real Time,Max RSS (kB),Baseline Elapsed Real Time,Baseline Max RSS (kB)" >> zray-gapbs-stats.csv
fi

kernels=("bc" "bfs" "cc" "cc_sv" "pr" "pr_spmv" "sssp" "tc")

BASE_DIR=$(pwd)
make clean
make -j8
# Uninstrumented binaries for the timing/RSS baseline. Built here so that each
# kernel's ZRay run and baseline run happen back to back below: this machine's
# run-to-run variance is larger than ZRay's overhead, so the two measurements have to
# share machine state to be comparable.
make -j8 baseline

for i in $(seq 0 7); do
    cd $BASE_DIR
    cd ${kernels[$i]}
    if [ $i -eq 6 ]; then
        KERNEL_ARGS="-f ../benchmark/graphs/twitter.wsg"
    else
        KERNEL_ARGS=""
    fi

    # Warm-up run, discarded. Reading the graph dominates wall time and is not
    # instrumented by either build, so if the control and the ZRay run saw different
    # page cache states that difference would land directly in the reported overhead.
    # Running the control once first puts both measured runs on a warm cache.
    ./${kernels[$i]}-baseline $KERNEL_ARGS > /dev/null 2>&1

    # Measured control, then measured ZRay run, back to back on the warm cache.
    /usr/bin/time -f "Time: %e\nMax RSS: %M" -o time-${kernels[$i]}-baseline.txt ./${kernels[$i]}-baseline $KERNEL_ARGS
    rm -f tool_log_file.txt
    /usr/bin/time -f "Time: %e\nMax RSS: %M\nAvg data+stack+text mem use: %K" -o time-${kernels[$i]}.txt ./${kernels[$i]} $KERNEL_ARGS
    HLD_CNT=$(grep "TOTAL HEAP LOAD" tool_log_file.txt | cut -c 1-19 --complement | paste -sd+ - | bc)
    HST_CNT=$(grep "TOTAL HEAP STORES" tool_log_file.txt | cut -c 1-19 --complement | paste -sd+ - | bc)
    LD_CNT=$(grep "TOTAL LOAD" tool_log_file.txt | cut -c 1-14 --complement | paste -sd+ - | bc)
    ST_CNT=$(grep "TOTAL STORES" tool_log_file.txt | cut -c 1-14 --complement | paste -sd+ - | bc)
    INSN_COUNT=$(grep "TOTAL INST" tool_log_file.txt | cut -c 1-20 --complement | paste -sd+ - | bc)
    TIME=$(grep "Time" time-${kernels[$i]}.txt | cut -c 1-6 --complement)
    MAX_RSS=$(grep "Max RSS" time-${kernels[$i]}.txt | cut -c 1-9 --complement)
    BASE_TIME=$(grep "Time" time-${kernels[$i]}-baseline.txt | cut -c 1-6 --complement)
    BASE_MAX_RSS=$(grep "Max RSS" time-${kernels[$i]}-baseline.txt | cut -c 1-9 --complement)
    echo ${kernels[$i]},$LD_CNT,$ST_CNT,$HLD_CNT,$HST_CNT,$INSN_COUNT,$TIME,$MAX_RSS,$BASE_TIME,$BASE_MAX_RSS >> ../zray-gapbs-stats.csv
done
cd $BASE_DIR
