#!/bin/bash

if [ ! -f ./pin-gapbs-stats.csv ]; then
    echo "Name,Total Loads,Total Stores,Elapsed Real Time (Uninstrumented),Elapsed Real Time (Pin),Max RSS (kB)" >> pin-gapbs-stats.csv
fi

kernels=("bc" "bfs" "cc" "cc_sv" "pr" "pr_spmv" "sssp" "tc")

BASE_DIR=$(pwd)
make clean
make

for i in $(seq 0 7); do
    cd $BASE_DIR
    cd ${kernels[$i]}
    if [ $i -eq 6 ]
    then
        /usr/bin/time -f "Time: %e\nMax RSS: %M\nAvg data+stack+text mem use: %K" -o time-${kernels[$i]}.txt ./${kernels[$i]} -f ../benchmark/graphs/twitter.wsg
        /usr/bin/time -f "Time: %e" -o time-delete-pin.txt $PIN_ROOT/pin -t $PIN_ROI_DIR/obj-intel64/roitrace-mt.so -- ./${kernels[$i]} -f ../benchmark/graphs/twitter.wsg
    else
        /usr/bin/time -f "Time: %e\nMax RSS: %M\nAvg data+stack+text mem use: %K" -o time-${kernels[$i]}.txt ./${kernels[$i]}
        /usr/bin/time -f "Time: %e" -o time-delete-pin.txt $PIN_ROOT/pin -t $PIN_ROI_DIR/obj-intel64/roitrace-mt.so -- ./${kernels[$i]}
    fi
    wait
	LD_CNT=$(grep "Total Number of Reads:" roitrace-mt.csv | cut -c 1-23 --complement | paste -sd+ - | bc)
	ST_CNT=$(grep "Total Number of Writes" roitrace-mt.csv | cut -c 1-24 --complement | paste -sd+ - | bc)
    TIME=$(grep "Time" time-${kernels[$i]}.txt | cut -c 1-6 --complement)
    MAX_RSS=$(grep "Max RSS" time-${kernels[$i]}.txt | cut -c 1-9 --complement)
    PIN_TIME=$(grep "Time" time-delete-pin.txt | cut -c 1-6 --complement)
    rm time-delete-pin.txt
    echo ${kernels[$i]},$LD_CNT,$ST_CNT,$TIME,$PIN_TIME,$MAX_RSS >> ../pin-gapbs-stats.csv
done
cd $BASE_DIR
