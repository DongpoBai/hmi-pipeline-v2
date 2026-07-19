#!/bin/bash
# ==============================================================================
# run_activity_differences.sh NN -- Part 5 D-stage driver (activity differences)
#
# Automates the interactive Fortran `hmirunNNactivity7differences`, the program
# that turns the merged 3-day activity table (C-stage output) into the paired
# activity differences used downstream. It replaces hand-typing the two stdin
# prompts. It does NOT modify any Fortran source, does NOT touch Rhodes' manual
# 3day*averages inputs, and does NOT rebuild anything.
#
# Confirmed facts this driver relies on (2026-07-18, Discovery):
#   - The exe reads two lines from stdin: (1) the activity dataset filename,
#     (2) NSETS = number of 3-day sets (= line count of the C-stage file).
#   - Input ACTIV_FN is the C-stage output 3dayaveactivityvalueshmirunNN.*.dat
#     (17-col, one row per 3-day set; run 80 had 24 rows).
#   - The exe hardcodes its output names (activ7diffshmirunNN.dat is an unused
#     0-byte handle; average7activdiffshmirunNN.dat is the real product) and
#     writes them to the current working directory. So we cd to the exe dir.
#   - The 6 per-run .f are identical except the run number, so this driver is
#     valid for any run whose exe has been built.
#
# Usage:
#   ./run_activity_differences.sh 80              # run it
#   ./run_activity_differences.sh 80 --dry-run    # show what it would do
#   ACTIV_FILE=/path/to/file.dat ./run_activity_differences.sh 80   # override input
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Args ─────────────────────────────────────────────────────────────────────
RUN_NUMBER=""
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) echo "Usage: $(basename "$0") NN [--dry-run]"; exit 0 ;;
        ''|*[!0-9]*) echo "ERROR: run number must be an integer, got: $arg" >&2; exit 1 ;;
        *) RUN_NUMBER="$arg" ;;
    esac
done
[[ -z "$RUN_NUMBER" ]] && { echo "ERROR: run number required. Usage: $(basename "$0") NN [--dry-run]" >&2; exit 1; }

# ── Content validation for the C-stage input (trust the data, not the name) ──
# The chosen input is checked against the invariants confirmed on run 80:
# 17 columns, seq (col1) contiguous +1, mdidn (col2) step 3, yearfract (col4)
# in a sane range. The yearfract check specifically catches the +1980 offset
# bug (which produced 2005.x) before it ever reaches the Fortran.
validate_activity_input() {
    local f="$1" errs=0 badcols badyf
    if [[ ! -s "$f" ]]; then echo "  [FAIL] input empty or missing: $f" >&2; return 1; fi
    badcols=$(awk 'NF!=17{print NR; exit}' "$f")
    if [[ -n "$badcols" ]]; then echo "  [FAIL] row ${badcols} does not have 17 columns" >&2; errs=$((errs+1)); fi
    awk '
      NR>1{
        if($1!=p1+1){print "  [FAIL] seq not contiguous @row"NR": "p1"->"$1; e++}
        if($2!=p2+3){print "  [FAIL] mdidn step != 3 @row"NR": "p2"->"$2; e++}
      }
      {p1=$1; p2=$2}
      END{exit (e>0)?1:0}
    ' "$f" >&2 || errs=$((errs+1))
    badyf=$(awk '$4<2015 || $4>2035 {print NR": "$4; exit}' "$f")
    if [[ -n "$badyf" ]]; then echo "  [FAIL] yearfract out of range (expect 2015-2035) @row${badyf}" >&2; errs=$((errs+1)); fi
    if [[ $errs -gt 0 ]]; then echo "  input validation FAILED (${errs} check(s))" >&2; return 1; fi
    echo "  [OK] input validated ($(grep -c '' "$f") rows, 17 cols, seq contiguous, mdidn step 3, yearfract in range)"
    return 0
}

# ── Locate the exe (per-run, in the pipeline dir; run from its directory) ─────
EXE_DIR="${ACTIV_EXE_DIR:-$SCRIPT_DIR}"
EXE="hmirun${RUN_NUMBER}activity7differences"
EXE_PATH="${EXE_DIR}/${EXE}"

if [[ ! -x "$EXE_PATH" ]]; then
    echo "ERROR: exe not found or not executable: ${EXE_PATH}" >&2
    echo "       (the per-run Fortran must be compiled first: ${EXE}.f -> ${EXE})" >&2
    exit 1
fi

# ── Locate the C-stage input (merge output), unless overridden ───────────────
if [[ -n "${ACTIV_FILE:-}" ]]; then
    IN_FILE="$ACTIV_FILE"
else
    # newest 3dayaveactivityvalueshmirunNN.*.dat in the exe dir
    IN_FILE=$(ls -1t "${EXE_DIR}/3dayaveactivityvalueshmirun${RUN_NUMBER}."*.dat 2>/dev/null | head -1 || true)
fi

if [[ -z "${IN_FILE:-}" || ! -f "$IN_FILE" ]]; then
    echo "ERROR: no C-stage input found for run ${RUN_NUMBER}." >&2
    echo "       Looked for ${EXE_DIR}/3dayaveactivityvalueshmirun${RUN_NUMBER}.*.dat" >&2
    echo "       Run the merge step (merge_3day_averages.py) first, or set ACTIV_FILE." >&2
    exit 1
fi

# The exe reads a *relative* filename from cwd (=EXE_DIR); pass just the basename.
IN_BASENAME="$(basename "$IN_FILE")"
NSETS=$(grep -c '' "$IN_FILE" | tr -d '[:space:]')   # line count = number of 3-day sets

OUT_FILE="${EXE_DIR}/average7activdiffshmirun${RUN_NUMBER}.dat"

echo "Run ${RUN_NUMBER} activity differences:"
echo "  exe   : ${EXE_PATH}"
echo "  input : ${IN_FILE}  (NSETS=${NSETS})"
echo "  output: ${OUT_FILE}"

# Validate the input content before doing anything with it (dry-run included).
if ! validate_activity_input "$IN_FILE"; then
    echo "ERROR: C-stage input failed validation; refusing to run the differences." >&2
    echo "       Fix or regenerate ${IN_FILE} (re-run the merge step) and retry." >&2
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] would run (in ${EXE_DIR}):"
    echo "           printf '%s\\n%s\\n' '${IN_BASENAME}' '${NSETS}' | ./${EXE}"
    exit 0
fi

# ── Run it: feed the two stdin lines, from the exe directory ─────────────────
( cd "$EXE_DIR" && printf '%s\n%s\n' "$IN_BASENAME" "$NSETS" | "./${EXE}" )

# ── Verify the real product (the 0-byte activ7diffs handle is ignored) ───────
if [[ ! -s "$OUT_FILE" ]]; then
    echo "ERROR: expected non-empty ${OUT_FILE}, but it is missing or empty." >&2
    exit 1
fi
OUT_LINES=$(grep -c '' "$OUT_FILE" | tr -d '[:space:]')
echo "OK: wrote ${OUT_FILE} (${OUT_LINES} lines)."