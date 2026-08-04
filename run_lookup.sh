#!/bin/bash
# ==============================================================================
# run_lookup.sh — Calculate MDIDN and date info for any HMI Run number
#
# Formula derived from:
#   Run  1: MDIDN = 6328  → 6256 + 1×72  = 6328  ✓
#   Run 74: MDIDN = 11584 → 6256 + 74×72 = 11584 ✓
#
# Usage:
#   ./run_lookup.sh 74          # Show info for Run 74
#   ./run_lookup.sh 74 80       # Show info for Runs 74 through 80
#   ./run_lookup.sh --all       # Show all known runs (1-80)
# ==============================================================================

MDIDN_OFFSET=6256   # MDIDN = OFFSET + RUN × 72
DAYS_PER_RUN=72
SETS_PER_RUN=24
DAYS_PER_SET=3

calc_mdidn() {
    local run=$1
    echo $(( MDIDN_OFFSET + run * DAYS_PER_RUN ))
}

print_run() {
    local run=$1
    local mdidn
    mdidn=$(calc_mdidn "$run")
    local last_mdidn=$(( mdidn + DAYS_PER_RUN - DAYS_PER_SET ))
    printf "Run %3d | MDIDN: %5d-%5d | SETL: %d\n" "$run" "$mdidn" "$last_mdidn" "$SETS_PER_RUN"
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--all" ]]; then
    echo "HMI 3-Day Runs — MDIDN Lookup Table"
    echo "Formula: MDIDN = 6256 + RUN_NUMBER × 72"
    echo "=================================================="
    for r in $(seq 1 80); do
        print_run "$r"
    done
elif [[ $# -eq 1 ]]; then
    print_run "$1"
    echo ""
    echo "For config file:"
    echo "  RUN_NUMBER=$1"
    echo "  MDIDN=$(calc_mdidn "$1")"
    echo "  SETL=${SETS_PER_RUN}"
elif [[ $# -eq 2 ]]; then
    for r in $(seq "$1" "$2"); do
        print_run "$r"
    done
else
    echo "Usage: $0 RUN_NUMBER [END_RUN]"
    echo "       $0 --all"
    exit 1
fi
