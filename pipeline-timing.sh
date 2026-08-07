#!/bin/bash
#
# TEMPORARY: run every step of the README's "At a glance" flow, recording wall
# time and peak RSS for each, so the artifact can quote realistic time and memory
# demands. Not part of the artifact proper -- delete once the numbers are taken.
#
# Usage:
#   ./pipeline-timing.sh [--spec-path=PATH] [step ...]
#
#   ./pipeline-timing.sh --spec-path=/proj/instrument-PG0/spec2017.iso
#   ./pipeline-timing.sh gapbs gapbs-pin          # just those two steps
#
# Steps: setup, gapbs, gapbs-pin, spec, spec-pin, report
#
# Results append to pipeline_timing.txt; the full `/usr/bin/time --verbose` dump
# for each step goes to pipeline_timing_raw.txt, and each step's own stdout/stderr
# to pipeline_logs/<step>.log.

ARTIFACT_HOME="$(cd "$(dirname "$0")" && pwd)"
cd "$ARTIFACT_HOME"

SUMMARY="$ARTIFACT_HOME/pipeline_timing.txt"
RAW="$ARTIFACT_HOME/pipeline_timing_raw.txt"
LOGDIR="$ARTIFACT_HOME/pipeline_logs"
SPEC_PATH="${SPEC_PATH:-}"

STEPS=()
for arg in "$@"; do
    case "$arg" in
        --spec-path=*) SPEC_PATH="${arg#*=}" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) STEPS+=("$arg") ;;
    esac
done

if [ ${#STEPS[@]} -eq 0 ]; then
    STEPS=(setup gapbs gapbs-pin spec spec-pin report)
fi

mkdir -p "$LOGDIR"

{
    echo "================================================================"
    echo "Pipeline timing run started $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host: $(hostname)   Cores: $(nproc)   Mem: $(free -g | awk '/^Mem:/{print $2}') GB"
    echo "================================================================"
    printf "%-14s %11s %14s %12s  %s\n" "STEP" "WALL" "WALL (h:mm:ss)" "PEAK RSS" "STATUS"
} >> "$SUMMARY"

run_step() {
    local name=$1; shift
    local t0 t1 secs rss status

    echo ">>> $name  ($(date '+%H:%M:%S'))"
    echo "===== $name =====" >> "$RAW"

    t0=$(date +%s)
    # --verbose gives Maximum resident set size; -a appends so every step's full
    # dump is kept. Peak RSS here is the largest single process in the step's
    # process tree, not the sum across concurrent children.
    /usr/bin/time --verbose -o "$RAW" -a "$@" > "$LOGDIR/$name.log" 2>&1
    status=$?
    t1=$(date +%s)
    secs=$((t1 - t0))

    # Take the last Max RSS recorded, i.e. the one this step just appended.
    rss=$(grep "Maximum resident set size" "$RAW" | tail -1 | grep -o '[0-9]*$')
    [ -n "$rss" ] || rss=0

    local pretty
    pretty=$(printf "%d:%02d:%02d" $((secs/3600)) $(((secs%3600)/60)) $((secs%60)))

    local verdict="ok"
    [ "$status" -eq 0 ] || verdict="FAILED (exit $status)"

    # Steps span 12 MB (the report) to tens of GB (GAPBS holding the Twitter
    # graph), so scale the unit rather than fixing it.
    local rss_h
    if [ "$rss" -ge 1048576 ]; then
        rss_h=$(awk -v k="$rss" 'BEGIN{printf "%.1f GB", k/1048576}')
    else
        rss_h=$(awk -v k="$rss" 'BEGIN{printf "%.1f MB", k/1024}')
    fi

    printf "%-14s %10ds %14s %12s  %s\n" \
        "$name" "$secs" "$pretty" "$rss_h" "$verdict" \
        | tee -a "$SUMMARY"
}

want() {
    local s
    for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done
    return 1
}

if want setup; then
    if [ -n "$SPEC_PATH" ]; then
        run_step setup ./setup.sh --with-pin --with-spec --spec-path="$SPEC_PATH"
    else
        echo "note: no --spec-path given, running setup without SPEC" | tee -a "$SUMMARY"
        run_step setup ./setup.sh --with-pin
    fi
fi

want gapbs     && run_step gapbs     ./run-gapbs.sh
want gapbs-pin && run_step gapbs-pin ./run-gapbs-pin.sh
want spec      && run_step spec      ./run-spec.sh
want spec-pin  && run_step spec-pin  ./run-spec-pin.sh
want report    && run_step report    python3 compare-zray-pin.py -o zray-pin-report.txt

{
    echo "----------------------------------------------------------------"
    echo "Finished $(date '+%Y-%m-%d %H:%M:%S')"
    echo
} >> "$SUMMARY"

echo
echo "Summary appended to $SUMMARY"
