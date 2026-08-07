#!/bin/bash
#
# Build every SPEC workload in all three variants: control, ZRay, and Pin.
#
# The flow is: let SPEC build the benchmarks normally so it records its exact
# compile and link commands in make.out, apply the ROI marker patches, then
# rebuild through the ZRay IR pipeline derived from those recorded commands.
# Deriving the pipeline from make.out rather than hand-writing it is what keeps
# the three variants identical in every respect except instrumentation.
#
# The stock SPEC build is always done from scratch, because the ROI patches are
# checksum-verified against pristine sources and will refuse to apply twice.

set -e

ARTIFACT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_INSTALL="${SPEC_INSTALL:-$ARTIFACT_HOME/spec2017}"
LABEL=zray
JOBS="${JOBS:-$(nproc)}"

# The 16 SPEC CPU2017 rate benchmarks written exclusively in C or C++.
WORKLOADS=(500.perlbench_r 502.gcc_r 505.mcf_r 508.namd_r 510.parest_r
           511.povray_r 519.lbm_r 520.omnetpp_r 523.xalancbmk_r 525.x264_r
           526.blender_r 531.deepsjeng_r 538.imagick_r 541.leela_r
           544.nab_r 557.xz_r)

if [ $# -gt 0 ]; then
    WORKLOADS=("$@")
fi

if [ ! -x "$SPEC_INSTALL/bin/runcpu" ]; then
    echo "SPEC is not installed at $SPEC_INSTALL." >&2
    echo "Run: ./setup.sh --with-spec --spec-path=/path/to/spec2017.iso" >&2
    exit 1
fi

# The Pin variant is only built when the Pintool is available, so that a plain
# ./setup.sh (no --with-pin) still yields a working ZRay workflow.
VARIANTS="baseline zray"
if [ -f "$ARTIFACT_HOME/pintool/obj-intel64/roitrace-mt.so" ]; then
    VARIANTS="baseline zray pin"
fi

# Skip workloads that are already built, so the run scripts can call this
# unconditionally without paying the ~50 minute build every time. Pass
# FORCE_BUILD=1 to rebuild regardless.
if [ "${FORCE_BUILD:-0}" != "1" ]; then
    todo=()
    for w in "${WORKLOADS[@]}"; do
        bd="$SPEC_INSTALL/benchspec/CPU/$w/build/build_base_${LABEL}-m64.0000"
        rd="$SPEC_INSTALL/benchspec/CPU/$w/run/run_base_train_${LABEL}-m64.0000"
        built=0
        if [ -f "$bd/.zray-binary" ] && [ -f "$rd/zray.zlog" ]; then
            bin=$(cat "$bd/.zray-binary"); built=1
            for v in $VARIANTS; do
                [ -x "$rd/${bin}_$v" ] || built=0
            done
        fi
        [ "$built" -eq 1 ] || todo+=("$w")
    done
    if [ ${#todo[@]} -eq 0 ]; then
        echo "All ${#WORKLOADS[@]} SPEC workloads already built; nothing to do."
        exit 0
    fi
    echo "Building ${#todo[@]} of ${#WORKLOADS[@]} workloads (rest already built)."
    WORKLOADS=("${todo[@]}")
fi

# ZRay provides CUSTOM_OPT / CUSTOM_LINK / ZRAY_BIN_PATH; the pintool provides
# PIN_ROI_DIR. Both are referenced by the generated build scripts.
cd "$ARTIFACT_HOME/ZRay" && . ./setupEnv.sh
if [ -f "$ARTIFACT_HOME/pintool/env.sh" ]; then
    cd "$ARTIFACT_HOME/pintool" && . ./env.sh
fi

# Derive the SPEC config from the template ZRay ships. Regenerated every time
# rather than cached, so it always reflects the current SPEC_INSTALL path.
echo "==> Generating SPEC config"
python3 "$ARTIFACT_HOME/spec/make-spec-config.py" \
        --source "$ARTIFACT_HOME/ZRay/spec-cfg/zray-clang-llvm-linux-x86.cfg" \
        --spec "$SPEC_INSTALL" \
        --out "$SPEC_INSTALL/config/${LABEL}.cfg"

echo "==> Stock SPEC build (records make.out and creates run directories)"
cd "$SPEC_INSTALL"
. ./shrc
# --rebuild is required, not merely tidy: SPEC records built binaries under
# benchspec/CPU/<workload>/exe and otherwise reports "Up to date" and leaves the
# build directory alone. Since a previous run leaves that directory holding
# ROI-patched sources, skipping the rebuild would feed already-patched files back
# into the patch step, which the checksum guard then rejects.
runcpu --config=$LABEL --action=setup --size=train --tune=base \
       --copies=1 --noreportable --rebuild --define build_ncpus="$JOBS" \
       "${WORKLOADS[@]}"

echo "==> Applying ROI marker patches"
only_args=()
for w in "${WORKLOADS[@]}"; do only_args+=(--only "$w"); done
python3 "$ARTIFACT_HOME/spec/apply-roi-patches.py" \
        --spec "$SPEC_INSTALL" --label $LABEL "${only_args[@]}"

echo "==> Building instrumented variants"
build_one() {
    local w=$1
    local bd="$SPEC_INSTALL/benchspec/CPU/$w/build/build_base_${LABEL}-m64.0000"
    local rd="$SPEC_INSTALL/benchspec/CPU/$w/run/run_base_train_${LABEL}-m64.0000"

    # Not redirected to /dev/null: build_one is invoked under `||`, which
    # suppresses `set -e` for its whole body, so a failure here would otherwise
    # fall through silently to a missing-script error further down.
    if ! python3 "$ARTIFACT_HOME/spec/make-build-scripts.py" --build-dir "$bd"; then
        echo "  FAILED $w -- could not derive build scripts"
        return 1
    fi
    local bin
    bin=$(cat "$bd/.zray-binary")

    # The three variants name their intermediate IR per variant (foo.zray.ll and
    # so on), so they can share a build directory without racing. Running them
    # concurrently matters: SPEC's command lists have no internal parallelism, so
    # blender's ~47 minute build would otherwise be paid three times over.
    local pids=() rc=0 v
    for v in $VARIANTS; do
        ( cd "$bd" && ./$v-build.sh ) >"$bd/$v-build.log" 2>&1 &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    if [ "$rc" -ne 0 ]; then
        echo "  FAILED $w -- see $bd/*-build.log"
        return 1
    fi

    for v in $VARIANTS; do
        cp "$bd/${bin}_$v" "$rd/"
    done

    # ZRay writes static region metadata here at compile time and the runtime
    # pairs it with the dynamic counters. Without it in the run directory every
    # counter reports zero while timing still works, so the failure is silent.
    cp "$bd/$ZRAY_LOGFILE" "$rd/"

    echo "  ok $w -> $bin"
}

# Workloads run concurrently too, capped because opt's peak memory on the larger
# modules (blender, parest, xalancbmk) is measured in gigabytes.
PARALLEL="${PARALLEL:-5}"
status_dir=$(mktemp -d)
trap 'rm -rf "$status_dir"' EXIT

for w in "${WORKLOADS[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do sleep 2; done
    ( build_one "$w" || touch "$status_dir/$w.failed" ) &
done
wait

failed=$(find "$status_dir" -name '*.failed' | wc -l)

echo "==> Done. ${#WORKLOADS[@]} workloads, $failed failed."
[ "$failed" -eq 0 ]
