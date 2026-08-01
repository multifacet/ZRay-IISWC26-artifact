#!/bin/bash

ARTIFACT_HOME=`pwd`

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
echo "3. Building GAPBS"
cd $ARTIFACT_HOME/gapbs
make -j$(nproc)
make bench-graphs

# Optional - install pip, scipy and pandas for running a script that generates a summary csv with data volume rate geomeans for the entire suite
sudo apt install -y python3-pip
pip install scipy pandas
