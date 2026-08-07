#!/bin/bash

set -e

ARTIFACT_HOME="$(cd "$(dirname "$0")" && pwd)"
WITH_PIN=0
WITH_SPEC=0

# The SPEC2017 ISO is licensed and cannot be distributed with this artifact, so
# its location is always supplied by the user. SPEC_INSTALL is where the tree is
# unpacked to; run-spec.sh defaults to the same path.
SPEC_PATH="${SPEC_PATH:-}"
SPEC_INSTALL="${SPEC_INSTALL:-$ARTIFACT_HOME/spec2017}"

# The ROI patches applied to the SPEC sources are keyed by line number and
# guarded by checksums, so exactly one SPEC release is supported.
SPEC_EXPECTED_LABEL="CPU2017v1.0.2"

usage() {
    cat <<'EOF'
Usage: ./setup.sh [--with-pin] [--with-spec --spec-path=PATH]

Build ZRay and the instrumented GAPBS workloads.

  --with-pin          Also download Intel Pin, build the Pintool, and build the
                      Pin-instrumented workloads used for validation.
  --with-spec         Also install SPEC CPU2017. Requires --spec-path. The
                      workloads themselves are built by ./run-spec.sh on first
                      use, so setup only has to unpack the suite.
  --spec-path=PATH    Path to a SPEC CPU2017 ISO. May also be given as the
                      SPEC_PATH environment variable.
  --spec-install=PATH Where to install SPEC. Defaults to ./spec2017; set this to
                      place the tree on a larger filesystem.

The two --with flags compose: passing both builds every combination of suite and
tool.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-pin) WITH_PIN=1 ;;
        --with-spec) WITH_SPEC=1 ;;
        --spec-path=*) SPEC_PATH="${1#*=}" ;;
        --spec-path) shift; SPEC_PATH="${1:-}" ;;
        --spec-install=*) SPEC_INSTALL="${1#*=}" ;;
        --spec-install) shift; SPEC_INSTALL="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# Validate the SPEC arguments before doing any work, so a missing ISO fails in
# seconds rather than after the LLVM and GAPBS builds.
if [ "$WITH_SPEC" -eq 1 ] && [ -x "$SPEC_INSTALL/bin/runcpu" ]; then
    # Already installed, so the ISO is not needed again and re-running setup for
    # some other reason should not demand it.
    echo "SPEC already installed at $SPEC_INSTALL; skipping the ISO step."
    WITH_SPEC=0
    SPEC_ALREADY=1
fi

if [ "$WITH_SPEC" -eq 1 ]; then
    if [ -z "$SPEC_PATH" ]; then
        echo "--with-spec requires --spec-path=PATH (or SPEC_PATH in the environment)." >&2
        exit 1
    fi
    if [ ! -f "$SPEC_PATH" ]; then
        echo "SPEC ISO not found: $SPEC_PATH" >&2
        exit 1
    fi
    # Volume Identifier of the ISO 9660 Primary Volume Descriptor. Read directly
    # rather than via file(1) so this check has no external dependency.
    SPEC_LABEL=$(dd if="$SPEC_PATH" bs=1 skip=32808 count=32 2>/dev/null | tr -d '\0 ')
    if [ "$SPEC_LABEL" != "$SPEC_EXPECTED_LABEL" ]; then
        echo "Unsupported SPEC release: found '$SPEC_LABEL', need '$SPEC_EXPECTED_LABEL'." >&2
        echo "The ROI patches are checksum-pinned to that release and will not apply." >&2
        exit 1
    fi
fi

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

    # Share the graphs with gapbs/ rather than building a second copy. Both trees
    # run the same converter over the same input and produce byte-identical
    # output, so a private copy costs 75 GB, a second 31 GB download, and a second
    # conversion pass for nothing. The kernels only ever read these files.
    if [ ! -L benchmark/graphs ]; then
        rm -rf benchmark/graphs
        ln -s ../../gapbs/benchmark/graphs benchmark/graphs
    fi
    if [ ! -e benchmark/graphs/twitter.wsg ]; then
        echo "Expected gapbs/benchmark/graphs to hold the generated graphs." >&2
        exit 1
    fi
fi

if [ "$WITH_SPEC" -eq 1 ]; then
    echo "5. Installing SPEC CPU2017 from $SPEC_PATH"

    if [ -d "$SPEC_INSTALL" ]; then
        echo "   $SPEC_INSTALL already exists; skipping install."
    else
        # bsdtar reads ISO 9660 directly, which keeps this to a single sudo (the
        # apt call) rather than needing a privileged loop mount and a matching
        # umount on every failure path.
        sudo apt install -y libarchive-tools

        SPEC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/spec2017-iso.XXXXXX")
        trap 'chmod -R u+w "$SPEC_TMP" 2>/dev/null; rm -rf "$SPEC_TMP"' EXIT

        echo "   Extracting ISO (about 3 GB)"
        bsdtar -xf "$SPEC_PATH" -C "$SPEC_TMP"

        # An ISO 9660 image records read-only modes, and bsdtar reproduces them:
        # directories come out dr-xr-xr-x. Without restoring write permission the
        # extracted tree cannot be deleted afterwards, which under `set -e` aborts
        # this script and orphans ~3 GB in the temp directory.
        chmod -R u+w "$SPEC_TMP"
        chmod +x "$SPEC_TMP/install.sh"

        echo "   Installing to $SPEC_INSTALL"
        # -f installs without prompting, -i ignores any $SPEC already exported in
        # the caller's environment, which would otherwise redirect the install.
        ( cd "$SPEC_TMP" && ./install.sh -f -i -d "$SPEC_INSTALL" )

        rm -rf "$SPEC_TMP"
        trap - EXIT
    fi

    if [ ! -x "$SPEC_INSTALL/bin/runcpu" ]; then
        echo "SPEC install did not produce $SPEC_INSTALL/bin/runcpu" >&2
        exit 1
    fi
    echo "   SPEC CPU2017 $SPEC_EXPECTED_LABEL installed at $SPEC_INSTALL"
    echo "   Workloads will be built on the first ./run-spec.sh (about 50 minutes)."
fi

# Install packages required to generate the ZRay bandwidth-summary CSV.
sudo apt install -y python3-pip
pip install scipy pandas

if [ "$WITH_PIN" -eq 0 ]; then
    echo "Pin validation was not installed. To add it later, run: ./setup.sh --with-pin"
fi

if [ "$WITH_SPEC" -eq 0 ] && [ "${SPEC_ALREADY:-0}" -eq 0 ]; then
    echo "SPEC2017 was not installed. To add it later, run: ./setup.sh --with-spec --spec-path=PATH"
fi
