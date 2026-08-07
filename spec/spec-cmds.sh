#!/bin/bash
#
# Print the commands SPEC would run for a workload, rewritten to invoke one of
# our instrumented binaries instead of the stock one.
#
# Usage: spec-cmds.sh <run-dir> <binary-stem> <variant> [wrapper...]
#
# SPEC benchmarks are not one command each. perlbench runs three scripts, x264
# runs several encoder passes, and some read stdin from a file. specinvoke -n
# prints the exact list -- including SPEC's own numactl pinning and every
# redirection -- so it is the authority here rather than a hand-written
# invocation per workload, which is what the reference harness used and what
# would silently under-run the multi-command benchmarks.
#
# A wrapper (used to put Pin in front of the binary) is inserted between the
# redirections and the executable.

set -e

RUN_DIR=$1
BIN=$2
VARIANT=$3
shift 3
WRAPPER="$*"

LABEL=${LABEL:-zray}

RUN_DIR=$(cd "$RUN_DIR" && pwd)

# Run directories live at $SPEC/benchspec/CPU/<workload>/run/<rundir>, so the
# installation root is five levels up. Deriving it here keeps callers from having
# to source shrc just to reach specinvoke.
export SPEC=${SPEC:-$(cd "$RUN_DIR/../../../../.." && pwd)}
SPECINVOKE="$SPEC/bin/specinvoke"
if [ ! -x "$SPECINVOKE" ]; then
    echo "specinvoke not found at $SPECINVOKE" >&2
    exit 1
fi

cd "$RUN_DIR"

# The stock binary appears in the command list as <stem>_base.<label>-m64.
stock="${BIN}_base.${LABEL}-m64"
# The ./ is required: SPEC's own command names the binary by path, and the
# generated run.sh executes it from the run directory, so a bare name would be
# looked up on PATH and not found.
replacement="./${BIN}_${VARIANT}"
if [ -n "$WRAPPER" ]; then
    replacement="$WRAPPER ./${BIN}_${VARIANT}"
fi

# Replace ONLY the path-qualified occurrence, which is the executable. SPEC also
# embeds the binary name inside the output filenames it generates -- x264's is
# run_000-142_<binary>_x264.out -- and rewriting those corrupts the redirect
# target (a "./" lands mid-filename, naming a directory that does not exist), so
# the command fails with no output and no obvious cause.
"$SPECINVOKE" -n \
    | grep -vE '^#|^specinvoke exit' \
    | grep -v '^[[:space:]]*$' \
    | sed "s#\.\./run_base_[^/]*/${stock}#${replacement}#g"
