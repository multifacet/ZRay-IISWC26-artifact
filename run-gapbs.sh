#!/bin/bash

ARTIFACT_HOME=`pwd`

# Source the environment file so that the environment variable with the path to the ZRay library is set for the build process in collect-gapbs.sh
cd $ARTIFACT_HOME/ZRay
. ./setupEnv.sh

cd $ARTIFACT_HOME/gapbs

# collect-gapbs.sh appends a row per kernel and only writes the header when the file
# is absent, so a re-run would otherwise stack new rows onto the previous run's.
# Remove it here to make this script safe to re-run. The other ZRay summary CSVs are
# truncated by their own coalesce scripts.
rm -f zray-gapbs-stats.csv

./collect-gapbs.sh # Produces zray-gapbs-stats.csv, which has heap load and store counts, plus timing and RSS for the ZRay and uninstrumented baseline builds
./coalesce-bytes.sh # Produces zray-byte-stats.csv, which counts number of bytes read from/written to heap
./coalesce-bandwidth.sh # Produces zray-gapbs-bandwidth-stats.csv, which contains geomean (across all threads) data volume access rates for gapbs workloads
