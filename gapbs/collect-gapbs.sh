#!/bin/bash

if [ ! -f ./zray-gapbs-stats.csv ]; then
	echo "Name,Total Loads,Total Stores,Total Heap Loads,Total Heap Stores,Total Instruction Count,Elapsed Real Time,Max RSS (kB)" >> zray-gapbs-stats.csv
fi

kernels=("bc" "bfs" "cc" "cc_sv" "pr" "pr_spmv" "sssp" "tc")

BASE_DIR=$(pwd)
make clean
make -j8

for i in $(seq 0 7); do
    cd $BASE_DIR
    cd ${kernels[$i]}
    rm tool_log_file.txt
    if [ $i -eq 6 ]
    then
        /usr/bin/time -f "Time: %e\nMax RSS: %M\nAvg data+stack+text mem use: %K" -o time-${kernels[$i]}.txt ./${kernels[$i]} -f ../benchmark/graphs/twitter.wsg
    else
        /usr/bin/time -f "Time: %e\nMax RSS: %M\nAvg data+stack+text mem use: %K" -o time-${kernels[$i]}.txt ./${kernels[$i]}
    fi
    HLD_CNT=$(grep "TOTAL HEAP LOAD" tool_log_file.txt | cut -c 1-19 --complement | paste -sd+ - | bc)
    HST_CNT=$(grep "TOTAL HEAP STORES" tool_log_file.txt | cut -c 1-19 --complement | paste -sd+ - | bc)
    LD_CNT=$(grep "TOTAL LOAD" tool_log_file.txt | cut -c 1-14 --complement | paste -sd+ - | bc)
    ST_CNT=$(grep "TOTAL STORES" tool_log_file.txt | cut -c 1-14 --complement | paste -sd+ - | bc)
    INSN_COUNT=$(grep "TOTAL INST" tool_log_file.txt | cut -c 1-20 --complement | paste -sd+ - | bc)
    TIME=$(grep "Time" time-${kernels[$i]}.txt | cut -c 1-6 --complement)
    MAX_RSS=$(grep "Max RSS" time-${kernels[$i]}.txt | cut -c 1-9 --complement)
    echo ${kernels[$i]},$LD_CNT,$ST_CNT,$HLD_CNT,$HST_CNT,$INSN_COUNT,$TIME,$MAX_RSS >> ../zray-gapbs-stats.csv
done
cd $BASE_DIR
