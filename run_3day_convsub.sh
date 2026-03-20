#!/bin/bash
# ==============================================================================
# run_3day_convsub.sh — Part 4: Conversion and Subtraction
#
# Wraps the entire Part 4 pipeline for 3-day HMI processing:
#   1. Gunzip and clean (unzip .gz, concatenate errfp, convert to ratios)
#   2. Create 13 variable directories (mkdir13var)
#   3. Prepare subtraction and binning scripts (prepsubbin)
#   4. Run subtraction and binning (qsubsubbin)
#   5. Verify 276 binl + 276 binnu per variable directory
#
# Usage:
#   ./run_3day_convsub.sh --run 74 --test-container
#   ./run_3day_convsub.sh --run 74 --validate
#   ./run_3day_convsub.sh --run 74 --dry-run
#   ./run_3day_convsub.sh --run 74
#
# All original scripts are called untouched. This wrapper only orchestrates.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Parse CLI ────────────────────────────────────────────────────────────────
parse_common_args "$@"

# ── Initialize ───────────────────────────────────────────────────────────────
init_pipeline "part4_convsub" "$RUN_NUMBER"
load_config "$CONFIG_FILE"

# ── Key paths ────────────────────────────────────────────────────────────────
CONT_DATA_DIR="/home/rcf-57/astro0/data"
CONT_WMLTP_DIR="/home/rcf-04/astro10/wmltp/theor1.0"
CONT_SCRIPTS_DIR="${CONT_WMLTP_DIR}/scripts"

HOST_DATA_DIR="${PROJECT_BASE}/rcf-57/astro0/data"
HOST_WMLTP_DIR="${PROJECT_BASE}/rcf-04/astro10/wmltp/theor1.0"

# The 13 variable directory prefixes (same order as in original scripts)
VAR_DIRS=(
    ampall_asymrlnew86_hmi
    amprats_asymrlnew86_hmi
    amprat2_asymrlnew86_hmi
    asymall_rlnew86_hmi
    asymrats_rlnew86_hmi
    freqall_asymrlnew86_hmi
    freqrats_asymrlnew86_hmi
    powall_asymrlnew86_hmi
    powrats_asymrlnew86_hmi
    powrat2_asymrlnew86_hmi
    widthall_asymrlnew86_hmi
    widthrats_asymrlnew86_hmi
    widthrat2_asymrlnew86_hmi
)
F96="final96b2b4rev6wtdhpccdprr"

# ==============================================================================
# MODE: --test-container
# ==============================================================================
if [[ "$TEST_CONTAINER" == "true" ]]; then
    run_container_test
    exit $?
fi

# ==============================================================================
# MODE: --validate
# ==============================================================================
if [[ "$VALIDATE" == "true" ]]; then
    banner "VALIDATE MODE: Checking Part 4 outputs for Run ${RUN_NUMBER}"

    PASS_COUNT=0
    FAIL_COUNT=0

    for vardir in "${VAR_DIRS[@]}"; do
        full_dir="${HOST_WMLTP_DIR}/${vardir}${MDIDN}/${F96}"

        if [[ ! -d "$full_dir" ]]; then
            log_error "[MISSING] ${vardir}${MDIDN}/${F96}/"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi

        binl_count=$(find "$full_dir" -maxdepth 1 -name "1*binl" 2>/dev/null | wc -l)
        binnu_count=$(find "$full_dir" -maxdepth 1 -name "1*binnu" 2>/dev/null | wc -l)
        binl_count=$(echo "$binl_count" | tr -d '[:space:]')
        binnu_count=$(echo "$binnu_count" | tr -d '[:space:]')

        if [[ "$binl_count" -eq 276 && "$binnu_count" -eq 276 ]]; then
            log_info "[OK] ${vardir}: binl=${binl_count} binnu=${binnu_count}"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            log_error "[MISMATCH] ${vardir}: binl=${binl_count}/276 binnu=${binnu_count}/276"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    banner "Part 4 Validation Summary"
    log_info "Passed: ${PASS_COUNT}/13"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        log_error "Failed: ${FAIL_COUNT}/13"
        exit 1
    else
        log_info "All 13 variable directories have complete Part 4 outputs!"
        exit 0
    fi
fi

# ==============================================================================
# EXECUTION MODE
# ==============================================================================
log_warn "This script will execute commands that write to:"
log_warn "  ${HOST_WMLTP_DIR}/"
if [[ "$DRY_RUN" != "true" ]]; then
    confirm "Are you sure you want to proceed with Run ${RUN_NUMBER}?" || {
        log_info "Aborted by user."
        exit 0
    }
fi

# ── Step ordering for checkpoint/resume ──────────────────────────────────────
STEP_ORDER=(gunzipclean mkdir13var prepsubbin qsubsubbin verify)

RESUME_STEP=""
if [[ "$RESUME" == "true" ]] && load_checkpoint; then
    RESUME_STEP="$CHECKPOINT_STEP"
    log_info "Resuming from checkpoint: ${RESUME_STEP}"
fi

# ==============================================================================
# STEP 1: Gunzip and Clean
# ==============================================================================
banner "Step 1: Gunzip and Clean (convert .gz → .ratios + .wBratios)"

if ! should_skip "gunzipclean"; then
    sing_exec --ifort "gunzipandclean for MDIDN=${MDIDN}, ${INSTRUMENT}, SETL=${SETL}" \
        "cd ${CONT_SCRIPTS_DIR} && ./gunzipandcleanwtrev6rr.3day.sing.sh ${MDIDN} ${INSTRUMENT} ${SETL}"

    # Check: each date range D/ should have H*.ratios and H*.wBratios
    if [[ "$DRY_RUN" != "true" && ${#DATE_RANGES[@]} -gt 0 ]]; then
        DR_SAMPLE="${DATE_RANGES[0]}"
        D_DIR="${HOST_WMLTP_DIR}/weightedhmi${DR_SAMPLE}dpirlnewrr/fdxref61/lgcfnonncorall96b2b4rev6asm/D"
        ratios_count=$(find "$D_DIR" -maxdepth 1 -name "H*.ratios" 2>/dev/null | wc -l)
        wbratios_count=$(find "$D_DIR" -maxdepth 1 -name "H*.wBratios" 2>/dev/null | wc -l)
        log_info "Spot check ${DR_SAMPLE}: H*.ratios=${ratios_count}, H*.wBratios=${wbratios_count}"
        if [[ "$ratios_count" -lt 1 || "$wbratios_count" -lt 1 ]]; then
            log_error "Expected at least 1 ratios + 1 wBratios file. Check cleanup log."
        fi
    fi

    save_checkpoint "gunzipclean"
fi

# ==============================================================================
# STEP 2: Create 13 variable directories
# ==============================================================================
banner "Step 2: Create 13 variable directories (mkdir13var)"

if ! should_skip "mkdir13var"; then
    sing_exec --ifort "mkdir13var for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./mkdir13varwtrev6rr.sing.sh ${RUN_NUMBER}"

    save_checkpoint "mkdir13var"
fi

# ==============================================================================
# STEP 3: Prepare subtraction and binning
# ==============================================================================
banner "Step 3: Prepare subtraction and binning (prepsubbin)"

if ! should_skip "prepsubbin"; then
    sing_exec "prepsubbin for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./prepsubbinhmiwtrev6rr.sing.sh ${RUN_NUMBER}"

    save_checkpoint "prepsubbin"
fi

# ==============================================================================
# STEP 4: Run subtraction and binning
# ==============================================================================
banner "Step 4: Run subtraction and binning (qsubsubbin)"

if ! should_skip "qsubsubbin"; then
    log_info "This step runs sequentially through 13 variable dirs (~45 min total)"

    sing_exec --ifort "qsubsubbin for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./qsubsubbinhmiwtrev6rr.sing.sh ${RUN_NUMBER}"

    save_checkpoint "qsubsubbin"
fi

# ==============================================================================
# STEP 5: Verify output (276 binl + 276 binnu per variable dir)
# ==============================================================================
banner "Step 5: Verify subtraction and binning output"

if ! should_skip "verify"; then
    PASS_COUNT=0
    FAIL_COUNT=0

    for vardir in "${VAR_DIRS[@]}"; do
        full_dir="${HOST_WMLTP_DIR}/${vardir}${MDIDN}/${F96}"

        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "[WOULD CHECK] ${vardir}${MDIDN}/${F96}: 276 binl + 276 binnu"
            PASS_COUNT=$((PASS_COUNT + 1))
            continue
        fi

        binl_count=$(find "$full_dir" -maxdepth 1 -name "1*binl" 2>/dev/null | wc -l)
        binnu_count=$(find "$full_dir" -maxdepth 1 -name "1*binnu" 2>/dev/null | wc -l)
        binl_count=$(echo "$binl_count" | tr -d '[:space:]')
        binnu_count=$(echo "$binnu_count" | tr -d '[:space:]')

        if [[ "$binl_count" -eq 276 && "$binnu_count" -eq 276 ]]; then
            log_info "[OK] ${vardir}: binl=${binl_count} binnu=${binnu_count}"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            log_error "[FAIL] ${vardir}: binl=${binl_count}/276 binnu=${binnu_count}/276"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    if [[ $FAIL_COUNT -gt 0 ]]; then
        log_error "${FAIL_COUNT}/13 variable directories have incomplete output"
        exit 1
    fi
    log_info "All 13 variable directories verified: 276 binl + 276 binnu each"

    # Also run the official check script for a full report
    sing_exec "checkhmiwtrev6rr_binnubinl for Run ${RUN_NUMBER}" \
        "cd ${CONT_WMLTP_DIR} && ./checkhmiwtrev6rr_binnubinl.sing.sh ${RUN_NUMBER}"

    save_checkpoint "verify"
fi

# ==============================================================================
# Summary
# ==============================================================================
banner "Part 4 Summary"
log_info "Part 4 (Conversion and Subtraction) completed for Run ${RUN_NUMBER}"
clear_checkpoint
log_info ""
log_info "Next step: Part 5 (Solar Activity Indices) — handled by Dr. Rhodes"
log_info "Then:      Part 6 (Regression and Transposition)"
log_info "  ./run_3day_regtrans.sh --run ${RUN_NUMBER}"
