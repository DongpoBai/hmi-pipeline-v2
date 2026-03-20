#!/bin/bash
# ==============================================================================
# diff_testenv.sh — Compare test outputs vs production for validation
#
# Compares the files generated in testenv/ against the production copies
# in /project2/erhodes_44/ to verify the wrapper produces identical results.
#
# Usage:
#   ./diff_testenv.sh --run 74
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

RUN_NUMBER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run) RUN_NUMBER="$2"; shift 2 ;;
        *) echo "Usage: $0 --run RR"; exit 1 ;;
    esac
done
[[ -z "$RUN_NUMBER" ]] && { echo "ERROR: --run required"; exit 1; }

PROD=/project2/erhodes_44
TEST="${SCRIPT_DIR}/testenv"
MDIDN=$(echo "6256 + ($RUN_NUMBER * 72)" | bc)
THEOR="rcf-04/astro10/wmltp/theor1.0"

VAR_DIRS=(ampall_asymrlnew86_hmi amprats_asymrlnew86_hmi amprat2_asymrlnew86_hmi asymall_rlnew86_hmi asymrats_rlnew86_hmi freqall_asymrlnew86_hmi freqrats_asymrlnew86_hmi powall_asymrlnew86_hmi powrats_asymrlnew86_hmi powrat2_asymrlnew86_hmi widthall_asymrlnew86_hmi widthrats_asymrlnew86_hmi widthrat2_asymrlnew86_hmi)
F96="final96b2b4rev6wtdhpccdprr"

PASS=0
FAIL=0
SKIP=0

echo "=============================================="
echo "  Comparing testenv vs production — Run $RUN_NUMBER"
echo "=============================================="
echo ""

# ── Part 4: binl/binnu files in 13 variable dirs ─────────────────────────────
echo "--- Part 4: Subtraction/Binning outputs ---"
for vardir in "${VAR_DIRS[@]}"; do
    prod_dir="${PROD}/${THEOR}/${vardir}${MDIDN}/${F96}"
    test_dir="${TEST}/${THEOR}/${vardir}${MDIDN}/${F96}"

    if [[ ! -d "$test_dir" ]]; then
        echo "  [SKIP] ${vardir}: testenv dir missing"
        SKIP=$((SKIP + 1))
        continue
    fi
    if [[ ! -d "$prod_dir" ]]; then
        echo "  [SKIP] ${vardir}: production dir missing"
        SKIP=$((SKIP + 1))
        continue
    fi

    # Compare binl files
    diff_output=$(diff <(cd "$test_dir" && ls 1*binl 2>/dev/null | sort) \
                       <(cd "$prod_dir" && ls 1*binl 2>/dev/null | sort) 2>&1) || true
    if [[ -z "$diff_output" ]]; then
        # File lists match — now check content of a sample file
        sample=$(cd "$test_dir" && ls 1*binl 2>/dev/null | head -1)
        if [[ -n "$sample" ]]; then
            if diff -q "${test_dir}/${sample}" "${prod_dir}/${sample}" > /dev/null 2>&1; then
                echo "  [OK]   ${vardir}: binl files match (sampled ${sample})"
                PASS=$((PASS + 1))
            else
                echo "  [DIFF] ${vardir}: binl content differs! (${sample})"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "  [EMPTY] ${vardir}: no binl files in testenv"
            FAIL=$((FAIL + 1))
        fi
    else
        test_count=$(cd "$test_dir" && ls 1*binl 2>/dev/null | wc -l)
        prod_count=$(cd "$prod_dir" && ls 1*binl 2>/dev/null | wc -l)
        echo "  [DIFF] ${vardir}: binl file count differs (test=${test_count} prod=${prod_count})"
        FAIL=$((FAIL + 1))
    fi
done

# ── Part 6: zero crossing files ──────────────────────────────────────────────
echo ""
echo "--- Part 6: Zero crossing outputs ---"

test_zc="${TEST}/${THEOR}/hmi3dayall13zerocrossings"
prod_zc="${PROD}/${THEOR}/hmi3dayall13zerocrossings"

for zc_file in "${prod_zc}"/zero_crossing.hmirun${RUN_NUMBER}rev6newrr.*.asym.out; do
    [[ ! -f "$zc_file" ]] && continue
    base=$(basename "$zc_file")
    test_file="${test_zc}/${base}"

    if [[ ! -f "$test_file" ]]; then
        echo "  [MISS] ${base}: not in testenv"
        FAIL=$((FAIL + 1))
        continue
    fi

    if diff -q "$test_file" "$zc_file" > /dev/null 2>&1; then
        echo "  [OK]   ${base}"
        PASS=$((PASS + 1))
    else
        # Show first difference
        first_diff=$(diff "$test_file" "$zc_file" | head -5)
        echo "  [DIFF] ${base}"
        echo "         ${first_diff}"
        FAIL=$((FAIL + 1))
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  PASS: ${PASS}  FAIL: ${FAIL}  SKIP: ${SKIP}"
echo "=============================================="

if [[ $FAIL -eq 0 && $SKIP -eq 0 ]]; then
    echo "  All outputs match production!"
    exit 0
elif [[ $FAIL -eq 0 ]]; then
    echo "  No failures, but ${SKIP} skipped (probably fewer test DRs)"
    exit 0
else
    echo "  ${FAIL} differences found — investigate before using in production"
    exit 1
fi
