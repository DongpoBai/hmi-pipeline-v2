#!/bin/bash
# ==============================================================================
# run_3day_activity.sh -- Part 5 (Activity Indices) top-level wrapper
#
# Part 5 has three stages:
#   Stage 1  daily indices   -- solar-activity-pipeline/generate_run.sh
#   Stage 2  3day averages    -- make_3day_averages.py: the six 3day*averages
#                                files, built from the daily indices. Dr. Rhodes
#                                used to make these by hand; the script reproduces
#                                his files (Runs 76-79: 575/576 lines byte-identical).
#   Stage 3+4 merge + diff    -- run_activity_merge.sh --then-diff
#
# If the six files for this run are already in the comparison directory (made
# by hand, or by an earlier run of this wrapper), stage 2 leaves them alone and
# uses them. Otherwise it builds them there, then carries on.
#
# It does NOT source lib/common.sh -- Part 5 runs outside the container, so it
# stays lightweight like its sub-scripts.
#
# Usage:
#   ./run_3day_activity.sh 79                 # stage 1 -> 2 -> merge+diff
#   ./run_3day_activity.sh 79 --dry-run        # show what each stage would do
#   ./run_3day_activity.sh 79 --skip-daily     # skip stage 1 (already generated)
#   ./run_3day_activity.sh 79 --auto-update    # pass --auto-update to stage 1
#
# Env:
#   ACTIVITY_PIPELINE_DIR  default /project2/erhodes_44/solar-activity-pipeline
#   COMPARISON_DIR         default .../mdi/lnu/comparison
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_BASE="${PROJECT_BASE:-/project2/erhodes_44}"
ACTIVITY_PIPELINE_DIR="${ACTIVITY_PIPELINE_DIR:-${PROJECT_BASE}/solar-activity-pipeline}"
MERGE_PY="${MERGE_PY:-${SCRIPT_DIR}/merge_3day_averages.py}"
MAKE_PY="${MAKE_PY:-${SCRIPT_DIR}/make_3day_averages.py}"
COMPARISON_DIR="${COMPARISON_DIR:-${PROJECT_BASE}/rcf-04/astro10/data/mdi/lnu/comparison}"
export COMPARISON_DIR

# ── Parse args ───────────────────────────────────────────────────────────────
RUN=""
DRY_RUN=false
SKIP_DAILY=false
AUTO_UPDATE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --skip-daily)  SKIP_DAILY=true; shift ;;
        --auto-update) AUTO_UPDATE=true; shift ;;
        -h|--help)
            echo "Usage: $(basename "$0") NN [--dry-run] [--skip-daily] [--auto-update]"
            exit 0 ;;
        -*)            echo "Unknown option: $1" >&2; exit 1 ;;
        *)             RUN="$1"; shift ;;
    esac
done
[[ -n "$RUN" ]] || { echo "ERROR: run number required. Usage: $(basename "$0") NN" >&2; exit 1; }
[[ "$RUN" =~ ^[0-9]+$ ]] || { echo "ERROR: run number must be an integer: $RUN" >&2; exit 1; }

say() { echo "[activity][run ${RUN}] $*"; }

# ── Stage 1: daily indices ───────────────────────────────────────────────────
GEN="${ACTIVITY_PIPELINE_DIR}/generate_run.sh"
if [[ "$SKIP_DAILY" == "true" ]]; then
    say "Stage 1 (daily indices): skipped (--skip-daily)"
else
    say "Stage 1 (daily indices): ${GEN} ${RUN}"
    if [[ ! -x "$GEN" ]]; then
        echo "ERROR: solar-activity-pipeline not found at:" >&2
        echo "  ${GEN}" >&2
        echo "Clone it there, or set ACTIVITY_PIPELINE_DIR:" >&2
        echo "  git clone https://github.com/HakuyuFujiwara/solar-activity-pipeline.git ${ACTIVITY_PIPELINE_DIR}" >&2
        echo "  (then build its venv per its DEPLOY_HPC.md)" >&2
        exit 1
    fi
    gen_args=("$RUN")
    [[ "$AUTO_UPDATE" == "true" ]] && gen_args+=("--auto-update")
    [[ "$DRY_RUN" == "true" ]] && gen_args+=("--dry-run")
    if [[ "$DRY_RUN" == "true" ]]; then
        say "[dry-run] would run: ${GEN} ${gen_args[*]}"
    fi
    "$GEN" "${gen_args[@]}"
fi

# ── Stage 2: the six 3day*averages files ─────────────────────────────────────
# merge_3day_averages.py --dry-run derives the date range from the daily-indices
# file and checks all six inputs, so its exit code says whether they exist.
six_present() { python3 "$MERGE_PY" --run "$RUN" --start-seq 1 --dry-run >/dev/null 2>&1; }

say "Stage 2 (3-day averages): checking for the six 3day*averages files..."
if six_present; then
    say "  All six already present; using them."
else
    DAILY="${COMPARISON_DIR}/dailyactivityvalueshmirun${RUN}.dat"
    STAMP="$(date +%m%d%y)"
    make_args=(--run "$RUN" --daily "$DAILY" --outdir "$COMPARISON_DIR" --allow-comparison --stamp "$STAMP")
    if [[ ! -s "$DAILY" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            say "  [dry-run] not present yet; stage 1 would write ${DAILY},"
            say "  then this stage would run: python3 ${MAKE_PY} ${make_args[*]}"
            say "  [dry-run] merge + differences preview needs those files; stopping here."
            exit 0
        fi
        echo "ERROR: daily indices file missing: ${DAILY}" >&2
        echo "       Run without --skip-daily so stage 1 produces it." >&2
        exit 1
    fi
    [[ -f "$MAKE_PY" ]] || { echo "ERROR: not found: ${MAKE_PY}" >&2; exit 1; }
    if [[ "$DRY_RUN" == "true" ]]; then
        say "  Not present. [dry-run] would run: python3 ${MAKE_PY} ${make_args[*]}"
        say "  [dry-run] merge + differences preview needs those files; stopping here."
        exit 0
    fi
    say "  Not present; building them: python3 ${MAKE_PY} ${make_args[*]}"
    if ! python3 "$MAKE_PY" "${make_args[@]}" 2>&1 | sed 's/^/    /'; then
        echo "ERROR: make_3day_averages.py stopped (see above); nothing merged." >&2
        exit 2
    fi
    chgrp erhodes_44 "$COMPARISON_DIR"/3day*averages.*."$STAMP".dat 2>/dev/null || true
    if ! six_present; then
        echo "ERROR: the six files are still not all found after building them." >&2
        python3 "$MERGE_PY" --run "$RUN" --start-seq 1 --dry-run 2>&1 | sed 's/^/    /' || true
        exit 2
    fi
    say "  Built all six."
fi

# ── Stage 3+4: merge then differences ────────────────────────────────────────
MERGE_SH="${SCRIPT_DIR}/run_activity_merge.sh"
[[ -x "$MERGE_SH" ]] || { echo "ERROR: not found: ${MERGE_SH}" >&2; exit 1; }
merge_args=("$RUN" "--then-diff")
[[ "$DRY_RUN" == "true" ]] && merge_args+=("--dry-run")
say "Stage 3+4 (merge + differences): ${MERGE_SH} ${merge_args[*]}"
"$MERGE_SH" "${merge_args[@]}"

say "Part 5 complete for run ${RUN}."
