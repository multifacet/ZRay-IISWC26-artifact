#!/bin/bash

echo "Name,Function,Time Elapsed,Read BW,Write BW" > zray-gapbs-bandwidth-stats.csv

kernels=("bc" "bfs" "cc" "cc_sv" "pr" "pr_spmv" "sssp" "tc")

functions=("PBFS" "BUStep" "Link" "ShiloachVishkin" "PageRankPullGS" "PageRankPull" "RelaxEdges" "OrderedCount")

BASE_DIR=$(pwd)

for i in $(seq 0 7); do
    cd $BASE_DIR
    cd ${kernels[$i]}
    grep "FUNCTION:\|TIME ELAPSED (ns)\|LOAD BW\|WRITE BW" tool_log_file.txt > coalesced.txt
    for j in $(seq 0 5); do
        vim -c "%s/FUNCTION:.*\n.*FUNCTION:/FUNCTION:/g" -c "%s/FUNCTION:.*\n.*FUNCTION:/FUNCTION:/g" -c "%s/FUNCTION:.*\n.*FUNCTION:/FUNCTION:/g" -c "wq" coalesced.txt
    done
    vim -c "%s/FUNCTION:.*\n.*-nan/-nan/g" -c "g/-nan/d" -c "%s/FUNCTION.*\n.*                   0/                   0/g" -c "g/                   0/d" -c "wq" coalesced.txt
    vim -c "%s/FUNCTION:.*\n.*                 inf/                 inf/g" -c "g/                 inf/d" -c "wq" coalesced.txt
    #sed -i '$d' coalesced.txt
    export prefix_metadata=${kernels[$i]},
    #export prefix_metadata=${kernels[$i]},${functions[$i]},
    vim -c "%s/\n.*TIME ELAPSED (ns):/,/g" -c "%s/\n.*LOAD BW (MB\/s):/,/g" -c "%s/\n.*WRITE BW (MB\/s):/,/g" -c "%s/.*FUNCTION://g" -c "wq" coalesced.txt
    vim -c "%s/ //g" -c "%s/,,/,/g" -c "%s/.*/$prefix_metadata&/g" -c "wq" coalesced.txt
    cat coalesced.txt >> ../zray-gapbs-bandwidth-stats.csv
    rm coalesced.txt
done
cd $BASE_DIR
python3 combine-multirun-bandwidths.py $BASE_DIR/zray-gapbs-bandwidth-stats.csv
#cat zray-gapbs-bandwidth-stats.csv | tail -n 12 >> zray-gapbs-bandwidth-stats-all.csv
