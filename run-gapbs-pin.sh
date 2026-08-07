#!/bin/bash

ARTIFACT_HOME=`pwd`

# Source the environment file so that the environment variable with the path to the ZRay library is set for the build process in collect-gapbs.sh
cd $ARTIFACT_HOME/ZRay
. ./setupEnv.sh
cd $ARTIFACT_HOME/pintool
. ./env.sh

if [ ! -x "$PIN_ROOT/pin" ] || [ ! -f "$PIN_ROI_DIR/obj-intel64/roitrace-mt.so" ]; then
    echo "Pin validation is not installed. Run ./setup.sh --with-pin first." >&2
    exit 1
fi

cd $ARTIFACT_HOME/gapbs-pin

# Both of these append a row per kernel and only write the header when the file is
# absent, so remove them here to make this script safe to re-run. Nothing under
# gapbs/ is touched, so the ZRay results and its uninstrumented baseline survive.
rm -f pin-gapbs-stats.csv pin-byte-stats.csv

./collect-gapbs.sh # Produces pin-gapbs-stats.csv, which has heap load and store counts
./coalesce-bytes.sh # Produces pin-byte-stats.csv, which counts number of bytes read from/written to heap
