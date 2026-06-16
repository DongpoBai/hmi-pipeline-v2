#!/bin/bash
# ==============================================================================
# validate_run.sh — Unified HMI Pipeline Validation (3-day + 72-day spectra)
#
# Checks output files from Part 1 through Part 6 for a given run number.
# Reports per-part status with file counts and a final summary.
#
# Usage:
#   ./validate_run.sh --run 80                       # 3-day full pipeline (default)
#   ./validate_run.sh --run 79 --mode 72day --part 1 # 72-day raw spectra only
#   ./validate_run.sh --run 79 --mode both           # 3-day full + 72-day spectra
#   ./validate_run.sh --run 80 --config config/run80.conf
#   ./validate_run.sh --run 80 --part 2              # check only Part 2
#   ./validate_run.sh --run 80 --part 3 --part 4     # check Parts 3 and 4
#   ./validate_run.sh --run 80 --verbose             # show every daterange detail
#   ./validate_run.sh --run 80 --brief               # one line per Part, no detail
#   ./validate_run.sh --batch 1 80                   # quick table for Rhodes (3-day)
#   ./validate_run.sh --run 79 --mode 72day --dr72 YYMMDDtoMMDD   # explicit 72-day DR
#
# --mode:
#   3day   (default)  full 3-day pipeline, Parts 1-6 — UNCHANGED from prior version
#   72day             72-day SPECTRA only (Parts 1 & 2); 3-6 are 3-day-specific
#   both              3-day full pipeline + 72-day spectra side by side
#
# 72-day daterange resolution priority:  --dr72  >  DATE_RANGE_72 (config)  >  auto-discover
#
# Requires: config file with DATE_RANGES array, or auto-discovers from filesystem.
# Does NOT require the Singularity container — all checks are plain filesystem reads.
#
# Exit codes:
#   0 = all checked parts fully pass
#   1 = at least one part has failures
#   2 = usage error / config not found
# ==============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
RUN_NUMBER=""
CONFIG_FILE=""
PROJECT_BASE="${PROJECT_BASE:-/project2/erhodes_44}"
VERBOSE=false
BRIEF=false
PARTS_TO_CHECK=()    # empty = all
BATCH_START=""
BATCH_END=""
OUTPUT_FILE=""       # --output file.txt
MODE="3day"          # 3day | 72day | both
DR72=""              # explicit 72-day daterange (overrides config/auto-discover)

# ── Colors (auto-disable if not a terminal) ──────────────────────────────────
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ── Logging helpers ──────────────────────────────────────────────────────────
pass()  { echo -e "  ${C_GREEN}✓${C_RESET} $*"; }
fail()  { echo -e "  ${C_RED}✗${C_RESET} $*"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $*"; }
info()  { echo -e "  ${C_CYAN}·${C_RESET} $*"; }
header(){ echo -e "\n${C_BOLD}═══ $* ═══${C_RESET}"; }

# ── Parse CLI ────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 --run RR [--mode 3day|72day|both] [--config FILE] [--part N ...] [--verbose] [--brief]"
    echo "       $0 --batch START END        Quick table for runs START..END (3-day)"
    echo ""
    echo "  --run RR        Run number (required unless --batch)"
    echo "  --mode M        3day (default) | 72day | both"
    echo "  --dr72 DR       Explicit 72-day daterange (YYMMDDtoMMDD); overrides auto-discover"
    echo "  --config FILE   Config file with DATE_RANGES array (auto-detected if omitted)"
    echo "  --part N        Check only Part N (repeatable; default: all)"
    echo "  --verbose       Show per-daterange detail for every Part"
    echo "  --brief         One-line summary per Part, no detail"
    echo "  --batch S E     Quick table for runs S through E (e.g. --batch 1 80)"
    echo "  --output FILE   Save batch report to FILE (plain text, no colors)"
    echo "  --base PATH     Override PROJECT_BASE (default: /project2/erhodes_44)"
    echo "  --help          Show this help"
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)      RUN_NUMBER="$2"; shift 2 ;;
        --mode)     MODE="$2"; shift 2 ;;
        --dr72)     DR72="$2"; shift 2 ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --part)     PARTS_TO_CHECK+=("$2"); shift 2 ;;
        --verbose)  VERBOSE=true; shift ;;
        --brief)    BRIEF=true; shift ;;
        --batch)    BATCH_START="$2"; BATCH_END="$3"; shift 3 ;;
        --output)   OUTPUT_FILE="$2"; shift 2 ;;
        --base)     PROJECT_BASE="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *)          echo "ERROR: Unknown argument: $1"; usage ;;
    esac
done

# ── Validate mode ────────────────────────────────────────────────────────────
case "$MODE" in
    3day|72day|both) ;;
    *) echo "ERROR: --mode must be one of: 3day | 72day | both (got '$MODE')"; usage ;;
esac
# Convenience flags for which spectra family to evaluate
NEED_3DAY=false; NEED_72DAY=false
[[ "$MODE" == "3day"  || "$MODE" == "both" ]] && NEED_3DAY=true
[[ "$MODE" == "72day" || "$MODE" == "both" ]] && NEED_72DAY=true

# ── Key paths (used by both single-run and batch) ────────────────────────────
WMLTP_BASE="${PROJECT_BASE}/rcf-04/astro10/wmltp/theor1.0"
COMPARISON_DIR="${PROJECT_BASE}/rcf-04/astro10/data/mdi/lnu/comparison"
ZEROCROSS_DIR="${WMLTP_BASE}/hmi3dayall13zerocrossings"

# 13 variable directory prefixes (exact naming from production)
VAR_DIRS=(
    "ampall_asymrlnew86_hmi"
    "amprats_asymrlnew86_hmi"
    "amprat2_asymrlnew86_hmi"
    "asymall_rlnew86_hmi"
    "asymrats_rlnew86_hmi"
    "freqall_asymrlnew86_hmi"
    "freqrats_asymrlnew86_hmi"
    "powall_asymrlnew86_hmi"
    "powrats_asymrlnew86_hmi"
    "powrat2_asymrlnew86_hmi"
    "widthall_asymrlnew86_hmi"
    "widthrats_asymrlnew86_hmi"
    "widthrat2_asymrlnew86_hmi"
)

# 13 zero-crossing variable suffixes
ZC_VARS=(nudiffs nurats amprats amprat2 ampdiffs powrats powrat2 powdiffs wirats wirat2 widiffs Brats Bdiffs)

# 2 representative variable dirs for quick Part 4 check in batch mode
SAMPLE_VAR_DIRS=("freqrats_asymrlnew86_hmi" "widthrats_asymrlnew86_hmi")

# ── MDIDN → 72-day daterange (deterministic) ─────────────────────────────────
# MDIDN is a plain day counter (1 unit = 1 calendar day). Anchor below was read
# off the live filesystem and verified to reproduce two independent runs:
#     Run 78  MDIDN 11872 -> 250704to0913   (observed on disk)
#     Run 79  MDIDN 11944 -> 250914to1124   (observed on disk)
# The 72-day window is [start, start+71] inclusive; dir name is YYMMDD"to"MMDD.
# If a particular run ever used a nonstandard dir name, override with --dr72.
DR72_ANCHOR_MDIDN=11872
DR72_ANCHOR_DATE="2025-07-04"
dr72_for_mdidn() {
    local mdidn=$1
    local off=$(( mdidn - DR72_ANCHOR_MDIDN ))
    local s e
    s=$(date -d "${DR72_ANCHOR_DATE} ${off} days" +%y%m%d 2>/dev/null) || { echo ""; return 1; }
    e=$(date -d "${DR72_ANCHOR_DATE} $((off + 71)) days" +%m%d 2>/dev/null) || { echo ""; return 1; }
    echo "${s}to${e}"
}

# ==============================================================================
# BATCH MODE (72-day spectra): compact one-row-per-run table for Part 1
# ==============================================================================
if [[ -n "$BATCH_START" && "$MODE" == "72day" ]]; then
    SPECTRA_BASE="${PROJECT_BASE}/rcf-93/data/spc/hmi"

    hdr=$(printf "%-5s %-7s  %-16s %-9s  %s" "Run" "MDIDN" "72day daterange" "P1 files" "Status")
    sep="───── ───────  ──────────────── ─────────  ──────────"
    echo ""
    echo -e "${C_BOLD}${hdr}${C_RESET}"
    echo "$sep"

    if [[ -n "$OUTPUT_FILE" ]]; then
        {
            echo "HMI 72-Day Raw Spectra (Part 1) Status"
            echo "Generated: $(date '+%Y-%m-%d %H:%M') on $(hostname)"
            echo "Runs: ${BATCH_START}–${BATCH_END}"
            echo ""
            echo "$hdr"; echo "$sep"
        } > "$OUTPUT_FILE"
    fi

    for rr in $(seq "$BATCH_START" "$BATCH_END"); do
        lmdidn=$(( 6256 + rr * 72 ))
        dr=$(dr72_for_mdidn "$lmdidn")
        dir="${SPECTRA_BASE}/${dr}dpirlrr"

        if [[ ! -d "$dir" ]]; then
            cnt="—"; status="MISSING"; col="$C_RED"
        else
            cnt=$(ls "$dir" 2>/dev/null | wc -l); cnt=$(echo "$cnt" | tr -d '[:space:]')
            if   [[ "$cnt" -eq 2003 ]]; then status="DONE";    col="$C_GREEN"
            elif [[ "$cnt" -eq 1001 ]]; then status="RAW";     col="$C_YELLOW"
            elif [[ "$cnt" -eq 0    ]]; then status="EMPTY";   col="$C_RED"
            else                              status="PARTIAL"; col="$C_RED"
            fi
        fi

        row=$(printf "%-5s %-7s  %-16s %-9s  %s" "$rr" "$lmdidn" "$dr" "$cnt" "$status")
        printf "%-5s %-7s  %-16s %-9s  " "$rr" "$lmdidn" "$dr" "$cnt"
        echo -e "${col}${status}${C_RESET}"
        [[ -n "$OUTPUT_FILE" ]] && echo "$row" >> "$OUTPUT_FILE"
    done

    echo ""
    echo -e "  ${C_CYAN}·${C_RESET} DONE=2003 (converted)  RAW=1001 (pre-convert)  PARTIAL=incomplete  EMPTY=dir but 0 files  MISSING=no dir"
    [[ -n "$OUTPUT_FILE" ]] && echo -e "\n  ${C_GREEN}✓${C_RESET} Report saved to: ${OUTPUT_FILE}"
    exit 0
fi

# ==============================================================================
# BATCH MODE: quick table for multiple runs (3-day; unchanged)
# ==============================================================================
if [[ -n "$BATCH_START" ]]; then

    # If --output, start the file with a header
    if [[ -n "$OUTPUT_FILE" ]]; then
        {
            echo "HMI 3-Day Pipeline Status Report"
            echo "Generated: $(date '+%Y-%m-%d %H:%M') on $(hostname)"
            echo "Runs: ${BATCH_START}–${BATCH_END}"
            echo ""
            echo "P1=Raw Spectra  P2=M-Avg/Renorm  P3=Fitting  P4=Conv/Sub/Bin  P5=Activity  P6=Regression/ZeroCross"
            echo ""
        } > "$OUTPUT_FILE"
    fi

    # Table header
    hdr=$(printf "%-5s %-7s  %-6s %-6s %-6s %-6s %-6s %-6s  %s" \
        "Run" "MDIDN" "P1" "P2" "P3" "P4" "P5" "P6" "Status")
    sep="───── ───────  ────── ────── ────── ────── ────── ──────  ──────────"

    echo ""
    echo -e "${C_BOLD}${hdr}${C_RESET}"
    echo "$sep"
    [[ -n "$OUTPUT_FILE" ]] && { echo "$hdr"; echo "$sep"; } >> "$OUTPUT_FILE"

    all_done=0; total_runs=0
    for rr in $(seq "$BATCH_START" "$BATCH_END"); do
        total_runs=$((total_runs + 1))
        lmdidn=$(( 6256 + rr * 72 ))
        lpad=$(printf "%02d" "$rr")

        # P6: 13 zero crossing files (definitive "done" marker)
        p6_ok=0
        for var in "${ZC_VARS[@]}"; do
            for f in "${ZEROCROSS_DIR}/zero_crossing.hmirun${rr}rev6newrr.all7.${var}.asym.out" \
                     "${ZEROCROSS_DIR}/zero_crossing.hmirun${lpad}rev6newrr.all7.${var}.asym.out"; do
                [[ -f "$f" ]] && { p6_ok=$((p6_ok + 1)); break; }
            done
        done

        # P5: activity index file
        p5_ok=false
        for f in "${COMPARISON_DIR}/average7activdiffshmirun${rr}.dat" \
                 "${COMPARISON_DIR}/average7activdiffshmirun${lpad}.dat"; do
            [[ -f "$f" ]] && { p5_ok=true; break; }
        done

        # P4: sample 2 variable dirs for *.binl
        p4_ok=0
        f96="final96b2b4rev6wtdhpccdprr"
        for vd in "${SAMPLE_VAR_DIRS[@]}"; do
            d="${WMLTP_BASE}/${vd}${lmdidn}/${f96}"
            if [[ -d "$d" ]]; then
                bn=$(find "$d" -maxdepth 1 -name '*.binl' 2>/dev/null | wc -l || echo 0)
                bn=$(echo "$bn" | tr -d '[:space:]')
                [[ "$bn" -eq 276 ]] && p4_ok=$((p4_ok + 1))
            fi
        done

        # P2: pwin dir has ≥26 files
        p2_ok=false
        pd="${PROJECT_BASE}/rcf-04/astro10/windowtest/HMIrun${rr}"
        if [[ -d "$pd" ]]; then
            pc=$(ls "$pd" 2>/dev/null | wc -l || echo 0)
            pc=$(echo "$pc" | tr -d '[:space:]')
            [[ $pc -ge 26 ]] && p2_ok=true
        fi

        # Format cells
        c_p1="--"
        $p2_ok   && c_p2="PASS" || c_p2="----"
        [[ $p6_ok -eq 13 ]] && c_p3="(ok)" || c_p3="----"
        [[ $p4_ok -eq 2 ]] && c_p4="PASS" || { [[ $p4_ok -gt 0 ]] && c_p4="PART" || c_p4="----"; }
        $p5_ok   && c_p5="PASS" || c_p5="----"
        [[ $p6_ok -eq 13 ]] && c_p6="PASS" || c_p6="----"
        [[ $p6_ok -eq 13 ]] && c_status="DONE" || c_status="INCOMPLETE"

        [[ "$c_status" == "DONE" ]] && all_done=$((all_done + 1))

        # Plain-text row (for file)
        row=$(printf "%-5s %-7s  %-6s %-6s %-6s %-6s %-6s %-6s  %s" \
            "$rr" "$lmdidn" "$c_p1" "$c_p2" "$c_p3" "$c_p4" "$c_p5" "$c_p6" "$c_status")

        # Terminal output (with colors)
        colorize() { [[ "$1" == "PASS" || "$1" == "(ok)" ]] && echo -ne "${C_GREEN}${1}${C_RESET}" || echo -ne "${C_RED}${1}${C_RESET}"; }

        printf "%-5s %-7s  " "$rr" "$lmdidn"
        echo -ne "$(colorize "$c_p1")    "
        echo -ne "$(colorize "$c_p2")  "
        echo -ne "$(colorize "$c_p3")  "
        echo -ne "$(colorize "$c_p4")  "
        echo -ne "$(colorize "$c_p5")  "
        echo -ne "$(colorize "$c_p6")  "
        [[ "$c_status" == "DONE" ]] && echo -e "  ${C_GREEN}DONE${C_RESET}" || echo -e "  ${C_RED}INCOMPLETE${C_RESET}"

        # File output (plain text)
        [[ -n "$OUTPUT_FILE" ]] && echo "$row" >> "$OUTPUT_FILE"
    done

    summary="Total: ${all_done} DONE out of ${total_runs} runs"
    echo ""
    echo -e "${C_BOLD}${summary}${C_RESET}"

    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "" >> "$OUTPUT_FILE"
        echo "$summary" >> "$OUTPUT_FILE"
        echo ""
        echo -e "  ${C_GREEN}✓${C_RESET} Report saved to: ${OUTPUT_FILE}"
    fi

    exit 0
fi

# ==============================================================================
# SINGLE-RUN MODE: requires --run
# ==============================================================================
[[ -z "$RUN_NUMBER" ]] && { echo "ERROR: --run is required (or use --batch S E)"; usage; }

# ── Compute MDIDN ───────────────────────────────────────────────────────────
MDIDN=$(( 6256 + RUN_NUMBER * 72 ))
RUN_PAD=$(printf "%02d" "$RUN_NUMBER")

# ── Additional paths for single-run mode ─────────────────────────────────────
SPECTRA_BASE="${PROJECT_BASE}/rcf-93/data/spc/hmi"
MAVG_BASE="${PROJECT_BASE}/rcf-57/astro0/data"
PWIN_DIR="${PROJECT_BASE}/rcf-04/astro10/windowtest/HMIrun${RUN_NUMBER}"

# ── Load config or auto-discover (3-day date ranges) ─────────────────────────
DATE_RANGES=()

if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Config file not found: $CONFIG_FILE"
        exit 2
    fi
    source "$CONFIG_FILE"
elif [[ -f "config/run${RUN_NUMBER}.conf" ]]; then
    source "config/run${RUN_NUMBER}.conf"
fi

# If still empty, try to discover the 3-day ranges from Part 1 directories on disk
if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
    for dir in "${SPECTRA_BASE}"/*dpirlrr; do
        [[ -d "$dir" ]] || continue
        dr=$(basename "$dir" | sed 's/dpirlrr$//')
        DATE_RANGES+=("$dr")
    done

    # Filter: keep only the 24 dateranges belonging to this run.
    # NOTE: this filter requires the 3-day mavg dir (avgspc2880) or fitting dir,
    # which naturally EXCLUDES any 72-day dir (it uses avgspc69120) sharing the
    # same SPECTRA_BASE/*dpirlrr namespace. So 3-day discovery is robust to 72-day
    # dirs being present.
    FILTERED=()
    for dr in "${DATE_RANGES[@]}"; do
        mavg_dir="${MAVG_BASE}/avgspc2880.wtnonavgcorrall.${dr}dpirlnewrr.hpcc"
        fitting_dir="${WMLTP_BASE}/weightedhmi${dr}dpirlnewrr"
        if [[ -d "$mavg_dir" ]] || [[ -d "$fitting_dir" ]]; then
            FILTERED+=("$dr")
        fi
    done

    if [[ ${#FILTERED[@]} -ge 20 && ${#FILTERED[@]} -le 24 ]]; then
        DATE_RANGES=("${FILTERED[@]}")
    else
        DR_LIST="${PROJECT_BASE}/rcf-57/astro0/data/run${RUN_PAD}.dateranges.lst"
        if [[ -f "$DR_LIST" ]]; then
            mapfile -t DATE_RANGES < "$DR_LIST"
        elif [[ -f "${PROJECT_BASE}/rcf-57/astro0/data/run${RUN_NUMBER}.dateranges.lst" ]]; then
            mapfile -t DATE_RANGES < "${PROJECT_BASE}/rcf-57/astro0/data/run${RUN_NUMBER}.dateranges.lst"
        else
            DATE_RANGES=()
        fi
    fi
fi

NUM_DR=${#DATE_RANGES[@]}

# 3-day ranges are REQUIRED only if the mode actually evaluates the 3-day pipeline.
if [[ "$NEED_3DAY" == "true" && $NUM_DR -eq 0 ]]; then
    if [[ "$MODE" == "3day" ]]; then
        echo "ERROR: Cannot determine 3-day date ranges for Run ${RUN_NUMBER}."
        echo "       Provide --config or ensure dateranges list exists."
        exit 2
    else
        # mode=both: 3-day ranges absent (e.g. spectra being rebuilt) — skip 3-day,
        # still allow the 72-day spectra checks to run.
        warn "No 3-day date ranges found for Run ${RUN_NUMBER}; skipping 3-day checks (mode=both)."
        NEED_3DAY=false
    fi
fi

# ── Resolve the single 72-day daterange (only when needed) ───────────────────
# Priority: --dr72  >  DATE_RANGE_72 (config)  >  computed from MDIDN.
# The computation is deterministic and verified (see dr72_for_mdidn anchor), so
# it works even when the 3-day spectra are absent (e.g. mid-rebuild). No noisy
# filesystem candidate scan; if a run used a nonstandard dir name, pass --dr72.
DR72_RESOLVED=""
DR72_METHOD=""
resolve_dr72() {
    if [[ -n "$DR72" ]]; then
        DR72_RESOLVED="$DR72"; DR72_METHOD="--dr72"; return 0
    fi
    if [[ -n "${DATE_RANGE_72:-}" ]]; then
        DR72_RESOLVED="$DATE_RANGE_72"; DR72_METHOD="config"; return 0
    fi
    local computed; computed=$(dr72_for_mdidn "$MDIDN") || return 1
    [[ -z "$computed" ]] && return 1
    DR72_RESOLVED="$computed"; DR72_METHOD="computed from MDIDN"
    return 0
}

if [[ "$NEED_72DAY" == "true" ]]; then
    if ! resolve_dr72; then
        if [[ "$MODE" == "72day" ]]; then exit 2; fi
        # mode=both: don't abort the whole run; just disable 72-day checks
        warn "72-day daterange unresolved; skipping 72-day checks (mode=both)."
        NEED_72DAY=false
    fi
fi

# ── Should we check this part? ───────────────────────────────────────────────
should_check() {
    local part=$1
    if [[ ${#PARTS_TO_CHECK[@]} -eq 0 ]]; then
        return 0
    fi
    for p in "${PARTS_TO_CHECK[@]}"; do
        [[ "$p" == "$part" ]] && return 0
    done
    return 1
}

# ── Counters ─────────────────────────────────────────────────────────────────
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_WARN=0
PART_STATUS=()        # 3-day part status
PART_STATUS_72=()     # 72-day part status

record_part()    { PART_STATUS[$1]="$2"; }
record_part_72() { PART_STATUS_72[$1]="$2"; }

# ==============================================================================
# PART 1 (3-day): Raw Spectra (Data Transfer from JSOC)
# ==============================================================================
check_part1() {
    header "Part 1 [3day]: Raw Spectra (JSOC transfer)"

    local ok=0 bad=0
    for dr in "${DATE_RANGES[@]}"; do
        local dir="${SPECTRA_BASE}/${dr}dpirlrr"
        if [[ ! -d "$dir" ]]; then
            [[ "$BRIEF" != "true" ]] && fail "${dr}: directory missing"
            bad=$((bad + 1))
            continue
        fi
        local count
        count=$(ls "$dir" 2>/dev/null | wc -l)
        count=$(echo "$count" | tr -d '[:space:]')

        if [[ "$count" -eq 2003 ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "${dr}: ${count} files"
            ok=$((ok + 1))
        else
            [[ "$BRIEF" != "true" ]] && fail "${dr}: ${count}/2003 files"
            bad=$((bad + 1))
        fi
    done

    if [[ $bad -eq 0 ]]; then
        pass "Part 1 [3day]: ${ok}/${NUM_DR} dateranges complete (2003 files each)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 1 "PASS"
    else
        fail "Part 1 [3day]: ${ok}/${NUM_DR} OK, ${bad} incomplete"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 1 "FAIL"
    fi
}

# ==============================================================================
# PART 1 (72-day): Raw Spectra — single daterange
# ------------------------------------------------------------------------------
# Same base dir + dpirlrr suffix as 3-day (verified from the pipeline docs:
# 72-day scp target is rcf-93/data/spc/hmi/{daterange}dpirlrr). Expected count:
#   1001  = raw transferred (pre convert-fits-move)
#   2003  = after convert-fits-move
# Both are reported and accepted; the label states which state was found.
# *** CONFIRM the 1001/2003 thresholds against the live filesystem for one run. ***
# ==============================================================================
check_part1_72() {
    header "Part 1 [72day]: Raw Spectra — ${DR72_RESOLVED}"

    local dir="${SPECTRA_BASE}/${DR72_RESOLVED}dpirlrr"
    if [[ ! -d "$dir" ]]; then
        fail "72day raw spectra directory missing: ${dir}"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part_72 1 "FAIL"
        return
    fi

    local count
    count=$(ls "$dir" 2>/dev/null | wc -l)
    count=$(echo "$count" | tr -d '[:space:]')

    if [[ "$count" -eq 2003 ]]; then
        pass "Part 1 [72day]: ${count} files (converted, complete)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part_72 1 "PASS"
    elif [[ "$count" -eq 1001 ]]; then
        pass "Part 1 [72day]: ${count} files (raw transferred; convert-fits-move pending)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part_72 1 "PASS"
    elif [[ "$count" -eq 0 ]]; then
        fail "Part 1 [72day]: directory exists but is EMPTY (0 files — not downloaded)"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part_72 1 "FAIL"
    else
        fail "Part 1 [72day]: ${count} files (PARTIAL; expected 1001 raw or 2003 converted)"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part_72 1 "FAIL"
    fi
}

# ==============================================================================
# PART 2 (3-day): M-Averaging and Renormalization
# ==============================================================================
check_part2() {
    header "Part 2 [3day]: M-Averaging + Renormalization"

    # --- 2a: pwin files (26 pwin + 25 wf = 51 is normal) ---
    local pwin_count=0
    if [[ -d "$PWIN_DIR" ]]; then
        pwin_count=$(ls "$PWIN_DIR" 2>/dev/null | wc -l)
        pwin_count=$(echo "$pwin_count" | tr -d '[:space:]')
    fi

    if [[ "$pwin_count" -ge 26 ]]; then
        pass "Pwin: HMIrun${RUN_NUMBER} has ${pwin_count} files (≥26)"
    elif [[ "$pwin_count" -gt 0 ]]; then
        warn "Pwin: HMIrun${RUN_NUMBER} has ${pwin_count}/26 files"
    else
        fail "Pwin: HMIrun${RUN_NUMBER} directory missing or empty"
    fi

    # --- 2b: mavg and psdr per daterange ---
    local ok=0 bad=0
    for dr in "${DATE_RANGES[@]}"; do
        local mavg_dir="${MAVG_BASE}/avgspc2880.wtnonavgcorrall.${dr}dpirlnewrr.hpcc"
        if [[ ! -d "$mavg_dir" ]]; then
            [[ "$BRIEF" != "true" ]] && fail "${dr}: mavg directory missing"
            bad=$((bad + 1))
            continue
        fi

        local mavg_n psdr_n
        mavg_n=$(find "$mavg_dir" -maxdepth 1 -name 'Y*aspc2nonavdisc' 2>/dev/null | wc -l)
        psdr_n=$(find "$mavg_dir" -maxdepth 1 -name 'Y*cspc2nonavdisc' 2>/dev/null | wc -l)
        mavg_n=$(echo "$mavg_n" | tr -d '[:space:]')
        psdr_n=$(echo "$psdr_n" | tr -d '[:space:]')

        if [[ "$mavg_n" -eq 1001 && "$psdr_n" -eq 1001 ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "${dr}: mavg=${mavg_n} psdr=${psdr_n}"
            ok=$((ok + 1))
        else
            [[ "$BRIEF" != "true" ]] && fail "${dr}: mavg=${mavg_n}/1001 psdr=${psdr_n}/1001"
            bad=$((bad + 1))
        fi
    done

    if [[ $bad -eq 0 && "$pwin_count" -ge 26 ]]; then
        pass "Part 2 [3day]: ${ok}/${NUM_DR} dateranges complete"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 2 "PASS"
    else
        fail "Part 2 [3day]: ${ok}/${NUM_DR} mavg/psdr OK, pwin=${pwin_count}"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 2 "FAIL"
    fi
}

# ==============================================================================
# PART 2 (72-day): M-Averaging and Renormalization
# ------------------------------------------------------------------------------
# Directory base is avgspc69120 (vs 3-day avgspc2880); 69120 = 2880 × 24.
# File counts are the SAME as 3-day per the docs: 1001 Y*aspc2nonavdisc (mavg)
# and 1001 Y*cspc2nonavdisc (psdr).  Pwin is shared (HMIrun##), already covered
# by the 3-day check; not re-checked here.
# ==============================================================================
check_part2_72() {
    header "Part 2 [72day]: M-Averaging + Renormalization — ${DR72_RESOLVED}"

    local mavg_dir="${MAVG_BASE}/avgspc69120.wtnonavgcorrall.${DR72_RESOLVED}dpirlnewrr.hpcc"
    if [[ ! -d "$mavg_dir" ]]; then
        fail "72day mavg directory missing: avgspc69120...${DR72_RESOLVED}dpirlnewrr.hpcc"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part_72 2 "FAIL"
        return
    fi

    local mavg_n psdr_n
    mavg_n=$(find "$mavg_dir" -maxdepth 1 -name 'Y*aspc2nonavdisc' 2>/dev/null | wc -l)
    psdr_n=$(find "$mavg_dir" -maxdepth 1 -name 'Y*cspc2nonavdisc' 2>/dev/null | wc -l)
    mavg_n=$(echo "$mavg_n" | tr -d '[:space:]')
    psdr_n=$(echo "$psdr_n" | tr -d '[:space:]')

    if [[ "$mavg_n" -eq 1001 && "$psdr_n" -eq 1001 ]]; then
        pass "Part 2 [72day]: mavg=${mavg_n} psdr=${psdr_n} (complete)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part_72 2 "PASS"
    else
        fail "Part 2 [72day]: mavg=${mavg_n}/1001 psdr=${psdr_n}/1001"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part_72 2 "FAIL"
    fi
}

# ==============================================================================
# PART 3: Fitting (3-day only)
# ==============================================================================
check_part3() {
    header "Part 3: Fitting"

    local ok=0 bad=0
    for dr in "${DATE_RANGES[@]}"; do
        local fit_base="${WMLTP_BASE}/weightedhmi${dr}dpirlnewrr"
        if [[ ! -d "$fit_base" ]]; then
            [[ "$BRIEF" != "true" ]] && fail "${dr}: fitting directory missing"
            bad=$((bad + 1))
            continue
        fi

        # Auto-detect the lgc subdirectory (naming varies between runs)
        local d_dir=""
        for lgc in "$fit_base"/fdxref61/lgc*/D; do
            [[ -d "$lgc" ]] && d_dir="$lgc" && break
        done

        if [[ -z "$d_dir" ]]; then
            [[ "$BRIEF" != "true" ]] && fail "${dr}: no lgc*/D directory found"
            bad=$((bad + 1))
            continue
        fi

        # Check for fitting output: 8 gz files (pre-gunzip) OR converted output
        local gz_n errfp_n ratios_n
        gz_n=$(find "$d_dir" -maxdepth 1 -name 'H*errfp.gz' 2>/dev/null | wc -l)
        errfp_n=$(find "$d_dir" -maxdepth 1 -name 'H*.0001to1000.errfp' 2>/dev/null | wc -l)
        ratios_n=$(find "$d_dir" -maxdepth 1 -name 'H*11000.ratios' 2>/dev/null | wc -l)
        gz_n=$(echo "$gz_n" | tr -d '[:space:]')
        errfp_n=$(echo "$errfp_n" | tr -d '[:space:]')
        ratios_n=$(echo "$ratios_n" | tr -d '[:space:]')

        # Accept any of: 8 gz (raw), 1+ errfp (concatenated), 1+ ratios (converted)
        if [[ "$gz_n" -eq 8 ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "${dr}: ${gz_n} gz files (pre-gunzip)"
            ok=$((ok + 1))
        elif [[ "$ratios_n" -ge 1 ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "${dr}: converted (ratios present)"
            ok=$((ok + 1))
        elif [[ "$errfp_n" -ge 1 ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "${dr}: concatenated errfp present"
            ok=$((ok + 1))
        elif [[ "$gz_n" -gt 0 ]]; then
            [[ "$BRIEF" != "true" ]] && warn "${dr}: only ${gz_n}/8 gz files"
            bad=$((bad + 1))
        else
            [[ "$BRIEF" != "true" ]] && fail "${dr}: no fitting output"
            bad=$((bad + 1))
        fi
    done

    if [[ $bad -eq 0 ]]; then
        pass "Part 3: ${ok}/${NUM_DR} dateranges have fitting output"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 3 "PASS"
    else
        fail "Part 3: ${ok}/${NUM_DR} OK, ${bad} incomplete or missing"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 3 "FAIL"
    fi
}

# ==============================================================================
# PART 4: Conversion, Subtraction, and Binning (3-day only)
# ==============================================================================
check_part4() {
    header "Part 4: Conversion, Subtraction & Binning"

    local ok=0 bad=0
    local f96="final96b2b4rev6wtdhpccdprr"

    for vardir_prefix in "${VAR_DIRS[@]}"; do
        local full_dir="${WMLTP_BASE}/${vardir_prefix}${MDIDN}/${f96}"
        local short_name="${vardir_prefix}${MDIDN}"

        if [[ ! -d "$full_dir" ]]; then
            [[ "$BRIEF" != "true" ]] && fail "${short_name}: directory missing"
            bad=$((bad + 1))
            continue
        fi

        local binl_n binnu_n
        binl_n=$(find "$full_dir" -maxdepth 1 -name '*.binl' 2>/dev/null | wc -l)
        binnu_n=$(find "$full_dir" -maxdepth 1 -name '*.binnu' 2>/dev/null | wc -l)
        binl_n=$(echo "$binl_n" | tr -d '[:space:]')
        binnu_n=$(echo "$binnu_n" | tr -d '[:space:]')

        if [[ "$binl_n" -eq 276 && "$binnu_n" -eq 276 ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "${short_name}: binl=${binl_n} binnu=${binnu_n}"
            ok=$((ok + 1))
        else
            [[ "$BRIEF" != "true" ]] && fail "${short_name}: binl=${binl_n}/276 binnu=${binnu_n}/276"
            bad=$((bad + 1))
        fi
    done

    if [[ $bad -eq 0 ]]; then
        pass "Part 4: all 13 variable directories complete (276 binl + 276 binnu)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 4 "PASS"
    else
        fail "Part 4: ${ok}/13 OK, ${bad}/13 incomplete"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 4 "FAIL"
    fi
}

# ==============================================================================
# PART 5: Solar Activity Indices (3-day only)
# ==============================================================================
check_part5() {
    header "Part 5: Solar Activity Indices"

    local ok=0 bad=0

    # Primary check: average7activdiff file in comparison directory
    local actdiff_file="${COMPARISON_DIR}/average7activdiffshmirun${RUN_NUMBER}.dat"
    local actdiff_pad="${COMPARISON_DIR}/average7activdiffshmirun${RUN_PAD}.dat"

    if [[ -f "$actdiff_file" ]]; then
        local lines
        lines=$(wc -l < "$actdiff_file")
        pass "average7activdiffshmirun${RUN_NUMBER}.dat: ${lines} lines"
        ok=$((ok + 1))
    elif [[ -f "$actdiff_pad" ]]; then
        local lines
        lines=$(wc -l < "$actdiff_pad")
        pass "average7activdiffshmirun${RUN_PAD}.dat: ${lines} lines"
        ok=$((ok + 1))
    else
        fail "average7activdiffshmirun${RUN_NUMBER}.dat not found in comparison/"
        bad=$((bad + 1))
    fi

    # Secondary check: 3dayaveactivityvalues file
    local found_actval=false
    for f in "${COMPARISON_DIR}"/3dayaveactivityvalueshmirun${RUN_NUMBER}.*.dat \
             "${COMPARISON_DIR}"/3dayaveactivityvalueshmirun${RUN_PAD}.*.dat; do
        if [[ -f "$f" ]]; then
            [[ "$VERBOSE" == "true" ]] && pass "$(basename "$f") found"
            found_actval=true
            break
        fi
    done
    if [[ "$found_actval" == "false" ]]; then
        warn "3dayaveactivityvalues file not found (may be pending Rhodes)"
    fi

    if [[ $bad -eq 0 && $ok -gt 0 ]]; then
        pass "Part 5: activity index files present"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 5 "PASS"
    elif [[ $ok -eq 0 && $bad -eq 0 ]]; then
        warn "Part 5: no files found (awaiting Dr. Rhodes?)"
        TOTAL_WARN=$((TOTAL_WARN + 1))
        record_part 5 "WARN"
    else
        fail "Part 5: missing activity index files"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 5 "FAIL"
    fi
}

# ==============================================================================
# PART 6: Regression and Transposition (3-day only)
# ==============================================================================
check_part6() {
    header "Part 6: Regression & Transposition (Zero Crossings)"

    local ok=0 bad=0

    for var in "${ZC_VARS[@]}"; do
        local zc_file="${ZEROCROSS_DIR}/zero_crossing.hmirun${RUN_NUMBER}rev6newrr.all7.${var}.asym.out"
        local zc_pad="${ZEROCROSS_DIR}/zero_crossing.hmirun${RUN_PAD}rev6newrr.all7.${var}.asym.out"

        if [[ -f "$zc_file" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                local lines
                lines=$(wc -l < "$zc_file")
                pass "${var}: ${lines} lines"
            fi
            ok=$((ok + 1))
        elif [[ -f "$zc_pad" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                local lines
                lines=$(wc -l < "$zc_pad")
                pass "${var}: ${lines} lines"
            fi
            ok=$((ok + 1))
        else
            [[ "$BRIEF" != "true" ]] && fail "${var}: zero_crossing file missing"
            bad=$((bad + 1))
        fi
    done

    if [[ $bad -eq 0 ]]; then
        pass "Part 6: all 13 zero crossing files present"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 6 "PASS"
    else
        fail "Part 6: ${ok}/13 OK, ${bad}/13 missing"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 6 "FAIL"
    fi
}

# ==============================================================================
# Main (single-run mode)
# ==============================================================================
echo ""
echo -e "${C_BOLD}Pipeline Validation — Run ${RUN_NUMBER} (mode=${MODE})${C_RESET}"
echo -e "  MDIDN:        ${MDIDN}"
echo -e "  PROJECT_BASE: ${PROJECT_BASE}"
if [[ "$NEED_3DAY" == "true" ]]; then
    echo -e "  3day ranges:  ${NUM_DR}"
    [[ $NUM_DR -gt 0 ]] && echo -e "  First / Last: ${DATE_RANGES[0]} / ${DATE_RANGES[${#DATE_RANGES[@]}-1]}"
fi
[[ "$NEED_72DAY" == "true" ]] && echo -e "  72day range:  ${DR72_RESOLVED}  (${DR72_METHOD})"

# Run 3-day part checks
if [[ "$NEED_3DAY" == "true" ]]; then
    for _p in 1 2 3 4 5 6; do
        if should_check "$_p"; then
            "check_part${_p}"
        else
            record_part "$_p" "SKIP"
        fi
    done
fi

# Run 72-day spectra checks (Parts 1 & 2 only; 3-6 are 3-day-specific)
if [[ "$NEED_72DAY" == "true" ]]; then
    for _p in 1 2; do
        if should_check "$_p"; then
            "check_part${_p}_72"
        else
            record_part_72 "$_p" "SKIP"
        fi
    done
    # If the user explicitly asked for a 3-6 part under mode=72day, say it's N/A.
    if [[ ${#PARTS_TO_CHECK[@]} -gt 0 ]]; then
        for p in "${PARTS_TO_CHECK[@]}"; do
            case "$p" in 3|4|5|6) warn "Part ${p} is not defined for 72-day spectra in this tool (3-day pipeline only).";; esac
        done
    fi
fi

# ==============================================================================
# Summary
# ==============================================================================
header "Summary — Run ${RUN_NUMBER} (mode=${MODE})"

label_for() {
    case $1 in
        1) echo "Raw Spectra" ;;
        2) echo "M-Avg + Renorm" ;;
        3) echo "Fitting" ;;
        4) echo "Conv/Sub/Bin" ;;
        5) echo "Activity Indices" ;;
        6) echo "Regression/ZeroCross" ;;
    esac
}
print_status_line() {
    local part=$1 status=$2 tag=$3
    local label; label=$(label_for "$part")
    case "$status" in
        PASS) echo -e "  Part ${part} ${tag} (${label}):  ${C_GREEN}PASS${C_RESET}" ;;
        FAIL) echo -e "  Part ${part} ${tag} (${label}):  ${C_RED}FAIL${C_RESET}" ;;
        WARN) echo -e "  Part ${part} ${tag} (${label}):  ${C_YELLOW}WARN${C_RESET}" ;;
        SKIP) echo -e "  Part ${part} ${tag} (${label}):  ${C_CYAN}SKIP${C_RESET}" ;;
    esac
}

if [[ "$NEED_3DAY" == "true" ]]; then
    for part in 1 2 3 4 5 6; do
        print_status_line "$part" "${PART_STATUS[$part]:-SKIP}" "[3day]"
    done
fi
if [[ "$NEED_72DAY" == "true" ]]; then
    for part in 1 2; do
        print_status_line "$part" "${PART_STATUS_72[$part]:-SKIP}" "[72day]"
    done
fi

echo ""
if [[ $TOTAL_FAIL -gt 0 ]]; then
    echo -e "${C_RED}${C_BOLD}Result: ${TOTAL_FAIL} part(s) FAILED${C_RESET}"
    exit 1
elif [[ $TOTAL_WARN -gt 0 ]]; then
    echo -e "${C_YELLOW}${C_BOLD}Result: All checked parts OK, ${TOTAL_WARN} warning(s)${C_RESET}"
    exit 0
else
    echo -e "${C_GREEN}${C_BOLD}Result: All checked parts PASS${C_RESET}"
    exit 0
fi