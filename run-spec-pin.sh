#!/bin/bash
#
# Run the SPEC2017 workloads under the Pintool.
#
# No control is timed here. Both tools are normalized against the single
# uninstrumented control produced by run-spec.sh, so that the two slowdown
# figures share a denominator. The uninstrumented run this script does perform is
# a page-cache warm-up only, and is recorded under that name.

set -e

ARTIFACT_HOME="$(cd "$(dirname "$0")" && pwd)"
SPEC_INSTALL="${SPEC_INSTALL:-$ARTIFACT_HOME/spec2017}"
LABEL=zray
export LABEL

WORKLOADS=(500.perlbench_r 502.gcc_r 505.mcf_r 508.namd_r 510.parest_r
           511.povray_r 519.lbm_r 520.omnetpp_r 523.xalancbmk_r 525.x264_r
           526.blender_r 531.deepsjeng_r 538.imagick_r 541.leela_r
           544.nab_r 557.xz_r)
SUBSET=0
if [ $# -gt 0 ]; then WORKLOADS=("$@"); SUBSET=1; fi

cd "$ARTIFACT_HOME/pintool" && . ./env.sh
cd "$ARTIFACT_HOME"

# Build anything not yet built. This is a no-op once the workloads exist, so the
# reviewer only ever needs ./setup.sh followed by this script.
# SPEC's generated run commands bind each run with numactl; without it every measured
# run exits 127. Check before building rather than after.
if ! command -v numactl > /dev/null 2>&1; then
    echo "numactl not found, but SPEC's run commands require it." >&2
    echo "Install it first:  sudo apt install -y numactl" >&2
    exit 1
fi

"$ARTIFACT_HOME/spec/build-spec.sh" "${WORKLOADS[@]}"

PINCMD="$PIN_ROOT/pin -t $PIN_ROI_DIR/obj-intel64/roitrace-mt.so --"

STATS="$ARTIFACT_HOME/spec-pin-stats.csv"
BYTES="$ARTIFACT_HOME/spec-pin-byte-stats.csv"
# Only reset the summary CSVs for a full run. A subset run (workloads given as
# arguments) appends instead, so re-measuring one workload cannot discard the
# other rows. The report reads the last row per workload, so an appended
# correction supersedes the earlier value.
if [ "$SUBSET" -eq 0 ]; then
    rm -f "$STATS" "$BYTES"
fi
if [ ! -s "$STATS" ]; then
    echo "Name,Total Loads,Total Stores,Warmup Elapsed Real Time,Elapsed Real Time (Pin),Warmup Max RSS (kB)" > "$STATS"
fi
if [ ! -s "$BYTES" ]; then
    echo "Name,Function,Read Bytes,Written Bytes" > "$BYTES"
fi

run_variant() {
    local rd=$1 bin=$2 variant=$3 timefile=$4 wrapper=$5
    local script="$rd/.run-pin-$variant.sh"
    local cmds="$rd/.cmds.txt"

    "$ARTIFACT_HOME/spec/spec-cmds.sh" "$rd" "$bin" "$variant" $wrapper > "$cmds"

    {
        echo "#!/bin/bash"
        echo "cd \"$rd\""
        if [ -n "$wrapper" ]; then
            # The Pintool opens roitrace-mt.csv with mode "w", so each invocation
            # truncates the previous one's results. Benchmarks that issue several
            # commands -- perlbench runs five -- would otherwise report only the
            # last. Accumulate after each command so the workload total covers
            # every invocation, matching how ZRay's log appends.
            echo ": > roitrace-accum.csv"
            while IFS= read -r c; do
                echo "$c"
                echo "cat roitrace-mt.csv >> roitrace-accum.csv 2>/dev/null || true"
            done < "$cmds"
        else
            cat "$cmds"
        fi
    } > "$script"
    chmod +x "$script"

    # Keep stderr: the workloads write their own output to SPEC's .out/.err files, so
    # anything here is the harness failing. Discarding it hid a missing numactl behind
    # a bare "exit 127".
    local errlog="$rd/.run-pin-$variant.err"
    local rc=0
    if [ -n "$timefile" ]; then
        /usr/bin/time -f "Time: %e\nMax RSS: %M" -o "$timefile" bash "$script" >/dev/null 2>"$errlog" || rc=$?
    else
        bash "$script" >/dev/null 2>"$errlog" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "    pin run failed (exit $rc)" >&2
        sed -n '1,3p' "$errlog" | sed 's/^/      /' >&2
        echo "      full stderr: $errlog" >&2
    fi
    return $rc
}

for w in "${WORKLOADS[@]}"; do
    bd="$SPEC_INSTALL/benchspec/CPU/$w/build/build_base_${LABEL}-m64.0000"
    rd="$SPEC_INSTALL/benchspec/CPU/$w/run/run_base_train_${LABEL}-m64.0000"
    name="${w#*.}"; name="${name%_r}"

    if [ ! -f "$bd/.zray-binary" ]; then echo "  skip $w (not built)"; continue; fi
    bin=$(cat "$bd/.zray-binary")

    echo "==> $w"
    # Uninstrumented run purely to warm the page cache before the Pin run.
    run_variant "$rd" "$bin" pin "$rd/time-pin-warmup.txt" ""
    rm -f "$rd/roitrace-mt.csv" "$rd/roitrace-accum.csv"
    run_variant "$rd" "$bin" pin "$rd/time-pin.txt" "$PINCMD"

    csv="$rd/roitrace-accum.csv"
    if [ ! -s "$csv" ]; then echo "  WARNING: no Pin output for $w"; continue; fi

    # Byte totals come from the per-function lines ("<func> Read Bytes:"), summed
    # across every function and thread, which is the same convention the GAPBS
    # coalesce script uses. Note "Total Number of Bytes Read" does not match this
    # pattern, so there is no double counting.
    sum() { grep "$1" "$csv" | grep -o '[0-9]*$' | paste -sd+ - | bc; }
    LD=$(sum "Total Number of Reads:"); ST=$(sum "Total Number of Writes")
    RB=$(sum "Read Bytes"); WB=$(sum "Write Bytes")
    FUNCS=$(sed -n 's/^Function:[[:space:]]*//p' "$csv" | sort -u | paste -sd";" -)

    WT=$(grep Time "$rd/time-pin-warmup.txt" | cut -d' ' -f2)
    WR=$(grep "Max RSS" "$rd/time-pin-warmup.txt" | cut -d' ' -f3)
    PT=$(grep Time "$rd/time-pin.txt" | cut -d' ' -f2)

    echo "$name,$LD,$ST,$WT,$PT,$WR" >> "$STATS"
    echo "$name,\"$FUNCS\",$RB,$WB" >> "$BYTES"
    echo "    warmup ${WT}s  pin ${PT}s  read ${RB}B  written ${WB}B"
done

echo "Wrote $STATS and $BYTES"
