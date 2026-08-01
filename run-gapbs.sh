#!/bin/bash

ARTIFACT_HOME=`pwd`

# Source the environment file so that the environment variable with the path to the ZRay library is set for the build process in collect-gapbs.sh
cd $ARTIFACT_HOME/ZRay
. ./setupEnv.sh

cd $ARTIFACT_HOME/gapbs
./collect-gapbs.sh # Produces zray-gapbs-stats.csv, which has heap load and store counts
./coalesce-bytes.sh # Produces zray-byte-stats.csv, which counts number of bytes read from/written to heap
./coalesce-bandwidth.sh # Produces zray-gapbs-bandwidth-stats.csv, which contains geomean (across all threads) data volume access rates for gapbs workloads
