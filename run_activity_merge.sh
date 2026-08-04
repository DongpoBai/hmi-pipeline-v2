#!/bin/bash
# ==============================================================================
# run_activity_merge.sh NN -- Part 5 C-stage driver (merge 3-day averages)
#
# Wraps merge_3day_averages.py: auto-derives --start-seq from the previous run's
# output (its last sequence number + 1), then merges the 6 manual 3day*averages
# inputs into the 17-column 3dayaveactivityvalueshmirunNN.<today>.dat.
#
# It does NOT create the 6 manual inputs (those are Rhodes' 3day*averages files);
# if they are absent, merge_3day_averages.py reports which are missing and this
# driver passes that through.
#
# Confirmed facts (2026-07-18, Discovery):
#   - start-seq is cumulative: run79 last seq 1896 -> run80 start 1897.
#     So start-seq(NN) = (last seq of run NN-1 output) + 1.
#   - The C-stage output is 3dayaveactivityvalueshmirunNN.<MMDDYY>.dat, one row
#     per 3-day set; its first column is the sequence number.
#
# Usage:
#   ./run_activity_merge.sh 81                 # auto start-seq, run merge
#   ./run_activity_merge.sh 81 --dry-run       # preview
#   ./run_activity_merge.sh 81 --start-seq 1921  # force start-seq
#   ./run_activity_merge.sh 81 --then-diff     # also run D-stage after merge
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARISON_DIR="${COMPARISON_DIR:-/project2/erhodes_44/rcf-04/astro10/data/mdi/lnu/comparison}"
MERGE_PY="${MERGE_PY:-${SCRIPT_DIR}/merge_3day_averages.py}"

RUN_NUMBER=""
DRY_RUN=false
FORCE_SEQ=""
THEN_DIFF=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --start-seq) FORCE_SEQ="$2"; shift 2 ;;
        --then-diff) THEN_DIFF=true; shift ;;
        -h|--help)   echo "Usage: $(basename "$0") NN [--dry-run] [--start-seq N] [--then-diff]"; exit 0 ;;
        ''|*[!0-9]*) echo "ERROR: unexpected arg: $1" >&2; exit 1 ;;
        *)           RUN_NUMBER="$1"; shift ;;
    esac
done
[[ -z "$RUN_NUMBER" ]] && { echo "ERROR: run number required." >&2; exit 1; }
[[ -f "$MERGE_PY" ]] || { echo "ERROR: merge script not found: ${MERGE_PY}" >&2; exit 1; }

# ── Derive start-seq from the previous run's output, unless forced ───────────
if [[ -n "$FORCE_SEQ" ]]; then
    START_SEQ="$FORCE_SEQ"
    echo "Using forced --start-seq ${START_SEQ}"
else
    PREV=$((RUN_NUMBER - 1))
    # newest previous-run output
    PREV_FILE=$(ls -1t "${COMPARISON_DIR}/3dayaveactivityvalueshmirun${PREV}."*.dat 2>/dev/null | head -1 || true)
    if [[ -z "${PREV_FILE:-}" || ! -f "$PREV_FILE" ]]; then
        echo "ERROR: cannot find previous-run output for run ${PREV}:" >&2
        echo "       ${COMPARISON_DIR}/3dayaveactivityvalueshmirun${PREV}.*.dat" >&2
        echo "       Pass --start-seq explicitly if run ${PREV} was not produced here." >&2
        exit 1
    fi
    LAST_SEQ=$(awk 'END{print $1}' "$PREV_FILE")
    if [[ -z "$LAST_SEQ" || ! "$LAST_SEQ" =~ ^[0-9]+$ ]]; then
        echo "ERROR: could not read last sequence number from ${PREV_FILE}" >&2
        exit 1
    fi
    START_SEQ=$((LAST_SEQ + 1))
    echo "Derived --start-seq ${START_SEQ} from ${PREV_FILE} (last seq ${LAST_SEQ})"
fi

# ── Run the merge ────────────────────────────────────────────────────────────
MERGE_ARGS=(--run "$RUN_NUMBER" --start-seq "$START_SEQ")
[[ "$DRY_RUN" == "true" ]] && MERGE_ARGS+=(--dry-run)

echo "Running: python3 ${MERGE_PY} ${MERGE_ARGS[*]}"
python3 "$MERGE_PY" "${MERGE_ARGS[@]}"

# ── Optionally chain into the D-stage (activity differences) ─────────────────
if [[ "$THEN_DIFF" == "true" ]]; then
    DIFF_DRIVER="${SCRIPT_DIR}/run_activity_differences.sh"
    if [[ ! -x "$DIFF_DRIVER" ]]; then
        echo "WARN: --then-diff requested but ${DIFF_DRIVER} not found/executable; skipping." >&2
    else
        echo ""
        echo "=== Chaining into D-stage (activity differences) ==="
        DIFF_ARGS=("$RUN_NUMBER")
        [[ "$DRY_RUN" == "true" ]] && DIFF_ARGS+=(--dry-run)
        "$DIFF_DRIVER" "${DIFF_ARGS[@]}"
    fi
fi
