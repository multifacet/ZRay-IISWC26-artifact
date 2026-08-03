#!/bin/bash

set -e

ARTIFACT_HOME="$(cd "$(dirname "$0")" && pwd)"
WITH_PIN=0

usage() {
    cat <<'EOF'
Usage: ./setup.sh [--with-pin]

Build ZRay and the instrumented GAPBS workloads. Pass --with-pin to also
download Intel Pin, build the Pintool, and build the Pin-instrumented GAPBS
workloads used for the optional validation experiment.
EOF
}

case "${1:-}" in
    "") ;;
    --with-pin) WITH_PIN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
esac

# Install LLVM-15
echo "1. Installing LLVM"
sudo apt update
sudo apt install -y llvm-15-dev clang-15 libomp-15-dev

# Build ZRay binaries
echo "2. Building ZRay"
git submodule init
git submodule update
cd $ARTIFACT_HOME/ZRay
./setup.sh
. ./setupEnv.sh

# Build GAPBS
echo "3. Building GAPBS with ZRay instrumentation"
cd $ARTIFACT_HOME/gapbs
make -j$(nproc)
make bench-graphs

if [ "$WITH_PIN" -eq 1 ]; then
    # Download Intel Pin and build the optional Pin validation workflow.
    PIN_TARBALL=pin-external-4.3-99850-gce5652921-gcc-linux.tar.gz
    PIN_URL=https://software.intel.com/sites/landingpage/pintool/downloads/$PIN_TARBALL
    cd "$ARTIFACT_HOME/pintool"
    if [ ! -f "$PIN_TARBALL" ]; then
        wget "$PIN_URL"
    fi
    tar -xf "$PIN_TARBALL"
    . ./env.sh
    ./build.sh

    echo "4. Building GAPBS with Pin instrumentation"
    cd "$ARTIFACT_HOME/gapbs-pin"
    make -j$(nproc)
    make bench-graphs
fi

# Install packages required to generate the ZRay bandwidth-summary CSV.
sudo apt install -y python3-pip
pip install scipy pandas

if [ "$WITH_PIN" -eq 0 ]; then
    echo "Pin validation was not installed. To add it later, run: ./setup.sh --with-pin"
fi
