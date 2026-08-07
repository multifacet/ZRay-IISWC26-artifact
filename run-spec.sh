#!/bin/bash
#
# Run the SPEC2017 workloads with ZRay, alongside an uninstrumented control.
#
# Each workload is run three times: a discarded warm-up, then the control, then
# the ZRay build. The warm-up exists because SPEC workloads read their inputs
# from disk, and an unequal page cache state between the two measured runs would
# show up as instrumentation overhead. The measured runs happen back to back so
# they share machine state.

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

# ZRay's runtime locates the static region metadata written at compile time via
# ZRAY_LOGFILE. Without it every counter reports zero while timing still works,
# so the failure is silent rather than loud.
cd "$ARTIFACT_HOME/ZRay" && . ./setupEnv.sh
cd "$ARTIFACT_HOME"

# Build anything not yet built. This is a no-op once the workloads exist, so the
# reviewer only ever needs ./setup.sh followed by this script.
"$ARTIFACT_HOME/spec/build-spec.sh" "${WORKLOADS[@]}"

STATS="$ARTIFACT_HOME/spec-zray-stats.csv"
BYTES="$ARTIFACT_HOME/spec-zray-byte-stats.csv"

# Only reset the summary CSVs for a full run. A subset run (workloads given as
# arguments) appends instead, so re-measuring one workload cannot discard the
# other rows. The report reads the last row per workload, so an appended
# correction supersedes the earlier value.
if [ "$SUBSET" -eq 0 ]; then
    rm -f "$STATS" "$BYTES"
fi
if [ ! -s "$STATS" ]; then
    echo "Name,Total Loads,Total Stores,Total Heap Loads,Total Heap Stores,Total Instruction Count,Elapsed Real Time,Max RSS (kB),Baseline Elapsed Real Time,Baseline Max RSS (kB)" > "$STATS"
fi
if [ ! -s "$BYTES" ]; then
    echo "Name,Function,Time Elapsed (ns),Max Thread Time Elapsed,Read Bytes,Written Bytes,Total Instructions,Counter Instructions,Counter Increments Contributing to Overhead" > "$BYTES"
fi

run_variant() {
    # Materialize the workload's command list and run it as one timed unit, since
    # several benchmarks issue multiple commands per run.
    local rd=$1 bin=$2 variant=$3 timefile=$4
    local script="$rd/.run-$variant.sh"
    { echo "#!/bin/bash"; echo "cd \"$rd\""
      "$ARTIFACT_HOME/spec/spec-cmds.sh" "$rd" "$bin" "$variant"; } > "$script"
    chmod +x "$script"
    if [ -n "$timefile" ]; then
        /usr/bin/time -f "Time: %e\nMax RSS: %M" -o "$timefile" bash "$script" >/dev/null 2>&1
    else
        bash "$script" >/dev/null 2>&1
    fi
}

for w in "${WORKLOADS[@]}"; do
    bd="$SPEC_INSTALL/benchspec/CPU/$w/build/build_base_${LABEL}-m64.0000"
    rd="$SPEC_INSTALL/benchspec/CPU/$w/run/run_base_train_${LABEL}-m64.0000"
    name="${w#*.}"; name="${name%_r}"

    if [ ! -f "$bd/.zray-binary" ]; then
        echo "  skip $w (not built)"; continue
    fi
    bin=$(cat "$bd/.zray-binary")

    echo "==> $w"
    run_variant "$rd" "$bin" baseline ""                        # warm-up, discarded
    run_variant "$rd" "$bin" baseline "$rd/time-baseline.txt"   # measured control
    rm -f "$rd/tool_log_file.txt"
    run_variant "$rd" "$bin" zray "$rd/time-zray.txt"           # measured ZRay

    log="$rd/tool_log_file.txt"
    if [ ! -f "$log" ]; then echo "  WARNING: no tool_log_file.txt for $w"; continue; fi

    # Sum across every region and every invocation: several workloads mark more
    # than one function, and multi-command benchmarks append one log block per
    # command. Workload-level totals are the only granularity at which ZRay's
    # region-keyed output and Pin's function-keyed output can be compared.
    sum() { grep "$1" "$log" | grep -o '[0-9]*$' | paste -sd+ - | bc; }
    HLD=$(sum "TOTAL HEAP LOADS"); HST=$(sum "TOTAL HEAP STORES")
    LD=$(sum "TOTAL LOADS"); ST=$(sum "TOTAL STORES")
    INSN=$(sum "TOTAL INST")
    TE=$(sum "TIME ELAPSED (ns)")
    MAXT=$(grep "TIME ELAPSED (ns)" "$log" | grep -o '[0-9]*$' | sort -n | tail -1)
    RB=$(sum "HEAP READ BYTES"); WB=$(sum "HEAP WRITTEN BYTES")
    CI=$(sum "COUNTER INST"); OV=$(sum "OVERHEAD INCREMENTS")
    FUNCS=$(grep "FUNCTION:" "$log" | sed 's/.*FUNCTION://' | tr -d ' ' \
            | grep -v '^$' | sort -u | paste -sd";" -)

    T=$(grep Time "$rd/time-zray.txt" | cut -d' ' -f2)
    R=$(grep "Max RSS" "$rd/time-zray.txt" | cut -d' ' -f3)
    BT=$(grep Time "$rd/time-baseline.txt" | cut -d' ' -f2)
    BR=$(grep "Max RSS" "$rd/time-baseline.txt" | cut -d' ' -f3)

    echo "$name,$LD,$ST,$HLD,$HST,$INSN,$T,$R,$BT,$BR" >> "$STATS"
    echo "$name,\"$FUNCS\",$TE,$MAXT,$RB,$WB,$INSN,$CI,$OV" >> "$BYTES"
    echo "    control ${BT}s  zray ${T}s  read ${RB}B  written ${WB}B"
done

echo "Wrote $STATS and $BYTES"
