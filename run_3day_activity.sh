#!/bin/bash
# ==============================================================================
# run_3day_activity.sh -- Part 5 (Activity Indices) top-level wrapper
#
# Part 5 has three stages, one of which is a manual wall:
#   Stage 1  daily indices   -- solar-activity-pipeline/generate_run.sh (automated)
#   Stage 2  3day averages    -- produced BY HAND (Dr. Rhodes): six 3day*averages
#                                files. The wrappers cannot cross this.
#   Stage 3+4 merge + diff    -- run_activity_merge.sh --then-diff (automated)
#
# This wrapper automates stages 1, 3, and 4, and stops cleanly at the stage-2
# wall: it runs stage 1, then checks whether the six manual files are present.
# If they are, it runs merge+diff. If not, it reports what is missing and exits,
# so you can come back and re-run once Dr. Rhodes has produced them.
#
# It does NOT source lib/common.sh -- Part 5 runs outside the container, so it
# stays lightweight like its sub-scripts.
#
# Usage:
#   ./run_3day_activity.sh 79                 # stage 1 -> check -> merge+diff
#   ./run_3day_activity.sh 79 --dry-run        # show what each stage would do
#   ./run_3day_activity.sh 79 --skip-daily     # skip stage 1 (already generated)
#   ./run_3day_activity.sh 79 --auto-update    # pass --auto-update to stage 1
#
# Env:
#   ACTIVITY_PIPELINE_DIR  default /project2/erhodes_44/solar-activity-pipeline
#   COMPARISON_DIR         default .../mdi/lnu/comparison (passed through)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_BASE="${PROJECT_BASE:-/project2/erhodes_44}"
ACTIVITY_PIPELINE_DIR="${ACTIVITY_PIPELINE_DIR:-${PROJECT_BASE}/solar-activity-pipeline}"
MERGE_PY="${MERGE_PY:-${SCRIPT_DIR}/merge_3day_averages.py}"

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

# ── Stage-2 wall: are the six manual 3day*averages files present? ────────────
# We reuse merge_3day_averages.py's own discovery (--dry-run): it derives the
# date range from the daily-indices file and checks all six inputs, so we don't
# re-implement the glob here. Its exit code IS the wall check.
say "Checking for the six manual 3day*averages inputs (Stage 2, produced by Dr. Rhodes)..."
if python3 "$MERGE_PY" --run "$RUN" --start-seq 1 --dry-run >/dev/null 2>&1; then
    say "  All six inputs present."
else
    echo "" >&2
    say "  Stage 2 is not complete yet -- the six manual 3day*averages files are"
    say "  not all present. This is the manual wall: Dr. Rhodes produces them by"
    say "  hand for this run's date range. Details from the merge step:"
    echo "" >&2
    # re-run without suppression so the user sees exactly what's missing
    python3 "$MERGE_PY" --run "$RUN" --start-seq 1 --dry-run 2>&1 | sed 's/^/    /' || true
    echo "" >&2
    say "  Once all six are in place, re-run:  $(basename "$0") ${RUN} --skip-daily"
    exit 2
fi

# ── Stage 3+4: merge then differences ────────────────────────────────────────
MERGE_SH="${SCRIPT_DIR}/run_activity_merge.sh"
[[ -x "$MERGE_SH" ]] || { echo "ERROR: not found: ${MERGE_SH}" >&2; exit 1; }
merge_args=("$RUN" "--then-diff")
[[ "$DRY_RUN" == "true" ]] && merge_args+=("--dry-run")
say "Stage 3+4 (merge + differences): ${MERGE_SH} ${merge_args[*]}"
"$MERGE_SH" "${merge_args[@]}"

say "Part 5 complete for run ${RUN}."
