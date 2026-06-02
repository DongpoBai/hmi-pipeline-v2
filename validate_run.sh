#!/bin/bash
# ==============================================================================
# validate_run.sh — Unified HMI 3-Day Pipeline Validation
#
# Checks all output files from Part 1 through Part 6 for a given run number.
# Reports per-part status with file counts and a final summary.
#
# Usage:
#   ./validate_run.sh --run 80
#   ./validate_run.sh --run 80 --config config/run80.conf
#   ./validate_run.sh --run 80 --part 2           # check only Part 2
#   ./validate_run.sh --run 80 --part 3 --part 4  # check Parts 3 and 4
#   ./validate_run.sh --run 80 --verbose           # show every daterange detail
#   ./validate_run.sh --run 80 --brief             # one line per Part, no detail
#   ./validate_run.sh --batch 1 80                 # quick table for Rhodes
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
    echo "Usage: $0 --run RR [--config FILE] [--part N ...] [--verbose] [--brief]"
    echo "       $0 --batch START END        Quick table for runs START..END"
    echo ""
    echo "  --run RR        Run number (required unless --batch)"
    echo "  --config FILE   Config file with DATE_RANGES array (auto-detected if omitted)"
    echo "  --part N        Check only Part N (repeatable; default: all)"
    echo "  --verbose       Show per-daterange detail for every Part"
    echo "  --brief         One-line summary per Part, no detail"
    echo "  --batch S E     Quick table for runs S through E (e.g. --batch 1 80)"
    echo "  --base PATH     Override PROJECT_BASE (default: /project2/erhodes_44)"
    echo "  --help          Show this help"
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)      RUN_NUMBER="$2"; shift 2 ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --part)     PARTS_TO_CHECK+=("$2"); shift 2 ;;
        --verbose)  VERBOSE=true; shift ;;
        --brief)    BRIEF=true; shift ;;
        --batch)    BATCH_START="$2"; BATCH_END="$3"; shift 3 ;;
        --base)     PROJECT_BASE="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *)          echo "ERROR: Unknown argument: $1"; usage ;;
    esac
done

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

# ==============================================================================
# BATCH MODE: quick table for multiple runs
# ==============================================================================
if [[ -n "$BATCH_START" ]]; then
    echo ""
    printf "${C_BOLD}%-5s %-7s  %-6s %-6s %-6s %-6s %-6s %-6s  %s${C_RESET}\n" \
        "Run" "MDIDN" "P1" "P2" "P3" "P4" "P5" "P6" "Status"
    printf "%s\n" "───── ───────  ────── ────── ────── ────── ────── ──────  ──────────"

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

        # Format cells (plain text, no color inside cells for alignment)
        c_p1="--"
        $p2_ok   && c_p2="PASS" || c_p2="----"
        # P3: infer from P6 (can't do regression without fitting)
        [[ $p6_ok -eq 13 ]] && c_p3="(ok)" || c_p3="----"
        [[ $p4_ok -eq 2 ]] && c_p4="PASS" || { [[ $p4_ok -gt 0 ]] && c_p4="PART" || c_p4="----"; }
        $p5_ok   && c_p5="PASS" || c_p5="----"
        [[ $p6_ok -eq 13 ]] && c_p6="PASS" || c_p6="----"

        # Overall status
        if [[ $p6_ok -eq 13 ]]; then
            c_status="${C_GREEN}DONE${C_RESET}"
            all_done=$((all_done + 1))
        else
            c_status="${C_RED}INCOMPLETE${C_RESET}"
        fi

        # Colorize cells for output
        colorize() { [[ "$1" == "PASS" || "$1" == "(ok)" ]] && echo -ne "${C_GREEN}${1}${C_RESET}" || echo -ne "${C_RED}${1}${C_RESET}"; }

        printf "%-5s %-7s  " "$rr" "$lmdidn"
        echo -ne "$(colorize "$c_p1")    "
        echo -ne "$(colorize "$c_p2")  "
        echo -ne "$(colorize "$c_p3")  "
        echo -ne "$(colorize "$c_p4")  "
        echo -ne "$(colorize "$c_p5")  "
        echo -ne "$(colorize "$c_p6")  "
        echo -e "  $c_status"
    done

    echo ""
    echo -e "${C_BOLD}Total: ${all_done} DONE out of ${total_runs} runs${C_RESET}"
    exit 0
fi

# ==============================================================================
# SINGLE-RUN MODE: requires --run
# ==============================================================================
[[ -z "$RUN_NUMBER" ]] && { echo "ERROR: --run is required (or use --batch S E)"; usage; }

# ── Compute MDIDN ───────────────────────────────────────────────────────────
MDIDN=$(( 6256 + RUN_NUMBER * 72 ))
RUN_PAD=$(printf "%02d" "$RUN_NUMBER")

# ── Load config or auto-discover ─────────────────────────────────────────────
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

# If still empty, try to discover from Part 1 directories on disk
if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
    SPECTRA_BASE="${PROJECT_BASE}/rcf-93/data/spc/hmi"
    for dir in "${SPECTRA_BASE}"/*dpirlrr; do
        [[ -d "$dir" ]] || continue
        dr=$(basename "$dir" | sed 's/dpirlrr$//')
        DATE_RANGES+=("$dr")
    done

    # Filter: keep only the 24 dateranges belonging to this run
    MAVG_BASE="${PROJECT_BASE}/rcf-57/astro0/data"
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
        fi
    fi
fi

if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
    echo "ERROR: Cannot determine date ranges for Run ${RUN_NUMBER}."
    echo "       Provide --config or ensure dateranges list exists."
    exit 2
fi

NUM_DR=${#DATE_RANGES[@]}

# ── Additional paths for single-run mode ─────────────────────────────────────
SPECTRA_BASE="${PROJECT_BASE}/rcf-93/data/spc/hmi"
MAVG_BASE="${PROJECT_BASE}/rcf-57/astro0/data"
PWIN_DIR="${PROJECT_BASE}/rcf-04/astro10/windowtest/HMIrun${RUN_NUMBER}"

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
PART_STATUS=()

record_part() {
    local part=$1 status=$2
    PART_STATUS[$part]="$status"
}

# ==============================================================================
# PART 1: Raw Spectra (Data Transfer from JSOC)
# ==============================================================================
check_part1() {
    header "Part 1: Raw Spectra (JSOC transfer)"

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
        pass "Part 1: ${ok}/${NUM_DR} dateranges complete (2003 files each)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 1 "PASS"
    else
        fail "Part 1: ${ok}/${NUM_DR} OK, ${bad} incomplete"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 1 "FAIL"
    fi
}

# ==============================================================================
# PART 2: M-Averaging and Renormalization
# ==============================================================================
check_part2() {
    header "Part 2: M-Averaging + Renormalization"

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
        pass "Part 2: ${ok}/${NUM_DR} dateranges complete"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        record_part 2 "PASS"
    else
        fail "Part 2: ${ok}/${NUM_DR} mavg/psdr OK, pwin=${pwin_count}"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        record_part 2 "FAIL"
    fi
}

# ==============================================================================
# PART 3: Fitting
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
# PART 4: Conversion, Subtraction, and Binning
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
# PART 5: Solar Activity Indices (prepared by Dr. Rhodes / merge script)
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
# PART 6: Regression and Transposition
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
echo -e "${C_BOLD}Pipeline Validation — Run ${RUN_NUMBER}${C_RESET}"
echo -e "  MDIDN:        ${MDIDN}"
echo -e "  Date ranges:  ${NUM_DR}"
echo -e "  PROJECT_BASE: ${PROJECT_BASE}"
echo -e "  First DR:     ${DATE_RANGES[0]}"
echo -e "  Last DR:      ${DATE_RANGES[${#DATE_RANGES[@]}-1]}"

# Run each part check
for _p in 1 2 3 4 5 6; do
    if should_check "$_p"; then
        "check_part${_p}"
    else
        record_part "$_p" "SKIP"
    fi
done

# ==============================================================================
# Summary
# ==============================================================================
header "Summary — Run ${RUN_NUMBER}"

for part in 1 2 3 4 5 6; do
    status="${PART_STATUS[$part]:-SKIP}"
    label=""
    case $part in
        1) label="Raw Spectra" ;;
        2) label="M-Avg + Renorm" ;;
        3) label="Fitting" ;;
        4) label="Conv/Sub/Bin" ;;
        5) label="Activity Indices" ;;
        6) label="Regression/ZeroCross" ;;
    esac

    case "$status" in
        PASS) echo -e "  Part ${part} (${label}):  ${C_GREEN}PASS${C_RESET}" ;;
        FAIL) echo -e "  Part ${part} (${label}):  ${C_RED}FAIL${C_RESET}" ;;
        WARN) echo -e "  Part ${part} (${label}):  ${C_YELLOW}WARN${C_RESET}" ;;
        SKIP) echo -e "  Part ${part} (${label}):  ${C_CYAN}SKIP${C_RESET}" ;;
    esac
done

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
