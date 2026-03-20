#!/bin/bash
# ==============================================================================
# run_3day_regtrans.sh — Part 6: Regression and Transposition
#
# Wraps the entire Part 6 pipeline for 3-day HMI processing:
#   1. Prep regression inputs
#   2. Run regression (all 13 variable directories)
#   3. Prep transposition and zero crossing
#   4. Run transposition and zero crossing
#   5. Verify 13 zero crossing output files
#   6. Run 2aves case
#
# NOTE: Original docs say runtranszero fails on discovery1 and needs discovery2.
#       The wrapper will warn about this. If it fails, SSH to discovery2 and
#       re-run with --resume.
#
# Usage:
#   ./run_3day_regtrans.sh --run 74 --test-container
#   ./run_3day_regtrans.sh --run 74 --validate
#   ./run_3day_regtrans.sh --run 74 --dry-run
#   ./run_3day_regtrans.sh --run 74
#
# All original scripts are called untouched. This wrapper only orchestrates.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Parse CLI ────────────────────────────────────────────────────────────────
parse_common_args "$@"

# ── Initialize ───────────────────────────────────────────────────────────────
init_pipeline "part6_regtrans" "$RUN_NUMBER"
load_config "$CONFIG_FILE"

# ── Key paths ────────────────────────────────────────────────────────────────
CONT_WMLTP_DIR="/home/rcf-04/astro10/wmltp/theor1.0"
CONT_SCRIPTS_DIR="${CONT_WMLTP_DIR}/scripts"

HOST_WMLTP_DIR="${PROJECT_BASE}/rcf-04/astro10/wmltp/theor1.0"
HOST_ZEROCROSS_DIR="${HOST_WMLTP_DIR}/hmi3dayall13zerocrossings"

# Expected zero crossing output files (13 variables)
ZC_VARS=(nudiffs nurats amprats amprat2 ampdiffs powrats powrat2 powdiffs wirats wirat2 widiffs Brats Bdiffs)

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
    banner "VALIDATE MODE: Checking Part 6 outputs for Run ${RUN_NUMBER}"

    RUN_PAD=$(printf "%02d" "$RUN_NUMBER")
    PASS_COUNT=0
    FAIL_COUNT=0

    # Check zero crossing files
    for var in "${ZC_VARS[@]}"; do
        zc_file="${HOST_ZEROCROSS_DIR}/zero_crossing.hmirun${RUN_NUMBER}rev6newrr.all7.${var}.asym.out"
        # Try without padding first, then with padding
        if [[ ! -f "$zc_file" ]]; then
            zc_file="${HOST_ZEROCROSS_DIR}/zero_crossing.hmirun${RUN_PAD}rev6newrr.all7.${var}.asym.out"
        fi

        if [[ -f "$zc_file" ]]; then
            line_count=$(wc -l < "$zc_file")
            log_info "[OK] ${var}: ${line_count} lines — $(basename "$zc_file")"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            log_error "[MISSING] zero_crossing.hmirun${RUN_NUMBER}rev6newrr.all7.${var}.asym.out"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    # Check prep regression output (304 or 857 files per variable dir)
    banner "Checking regression directory file counts"
    for vardir_base in freqrats_asymrlnew86_hmi widthrats_asymrlnew86_hmi; do
        f96dp_dir="${HOST_WMLTP_DIR}/${vardir_base}${MDIDN}/final96b2b4rev6wtdhpccdprr"
        if [[ -d "$f96dp_dir" ]]; then
            fcount=$(ls "$f96dp_dir" 2>/dev/null | wc -l)
            fcount=$(echo "$fcount" | tr -d '[:space:]')
            log_info "[INFO] ${vardir_base}${MDIDN}/final96...dprr: ${fcount} files"
        else
            log_warn "[WARN] ${vardir_base}${MDIDN}/final96...dprr not found"
        fi
    done

    banner "Part 6 Validation Summary"
    log_info "Zero crossing files: ${PASS_COUNT}/13"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        log_error "Missing: ${FAIL_COUNT}/13"
        exit 1
    else
        log_info "All 13 zero crossing output files present!"
        exit 0
    fi
fi

# ==============================================================================
# EXECUTION MODE
# ==============================================================================
log_warn "This script will execute commands that write to:"
log_warn "  ${HOST_WMLTP_DIR}/"
log_warn "  ${HOST_ZEROCROSS_DIR}/"
if [[ "$DRY_RUN" != "true" ]]; then
    confirm "Are you sure you want to proceed with Run ${RUN_NUMBER}?" || {
        log_info "Aborted by user."
        exit 0
    }
fi

# ── Step ordering ────────────────────────────────────────────────────────────
STEP_ORDER=(prepreg runreg preptrans runtrans verify aves)

RESUME_STEP=""
if [[ "$RESUME" == "true" ]] && load_checkpoint; then
    RESUME_STEP="$CHECKPOINT_STEP"
    log_info "Resuming from checkpoint: ${RESUME_STEP}"
fi

# ==============================================================================
# STEP 1: Prep regression
# ==============================================================================
banner "Step 1: Prep regression inputs"

if ! should_skip "prepreg"; then
    sing_exec --ifort "prepregresinp for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./prepregresinphmiwtrev6rr-dp2.sing.sh ${RUN_NUMBER}"

    # The output should show "304 304 NNNNN" or "857 857 NNNNN" for each of 13 dirs
    log_info "Check the output above: each line should show 304 or 857 files per directory"

    save_checkpoint "prepreg"
fi

# ==============================================================================
# STEP 2: Run regression
# ==============================================================================
banner "Step 2: Run regression (all 13 variable directories)"

if ! should_skip "runreg"; then
    log_info "This step produces a lot of Fortran EOF errors — that is NORMAL"
    log_info "Estimated time: ~5-10 minutes"

    sing_exec "runregres for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./runregreshmiwtrev6rr-dp2.sing.sh ${RUN_NUMBER}"

    save_checkpoint "runreg"
fi

# ==============================================================================
# STEP 3: Prep transposition and zero crossing
# ==============================================================================
banner "Step 3: Prep transposition and zero crossing"

if ! should_skip "preptrans"; then
    sing_exec "preptranszero for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./preptranszerohmiwtrev6rr-dp2.sing.sh ${RUN_NUMBER}"

    # Output should be a list of directories
    save_checkpoint "preptrans"
fi

# ==============================================================================
# STEP 4: Run transposition and zero crossing
# ==============================================================================
banner "Step 4: Run transposition and zero crossing"

if ! should_skip "runtrans"; then
    log_warn "NOTE: This step has historically failed on discovery1."
    log_warn "If it fails, SSH to discovery2 and re-run with --resume"
    log_info "Estimated time: ~5-10 minutes"

    sing_exec "runtranszero for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./runtranszerohmiwtrev6rr-dp2.sing.sh ${RUN_NUMBER}" || {
        log_error "runtranszero failed. Try from discovery2:"
        log_error "  ssh dongpoba@discovery2.usc.edu"
        log_error "  cd ${PIPELINE_DIR}"
        log_error "  ./run_3day_regtrans.sh --run ${RUN_NUMBER} --resume"
        exit 1
    }

    save_checkpoint "runtrans"
fi

# ==============================================================================
# STEP 5: Verify zero crossing outputs
# ==============================================================================
banner "Step 5: Verify zero crossing output files"

if ! should_skip "verify"; then
    PASS_COUNT=0
    FAIL_COUNT=0

    for var in "${ZC_VARS[@]}"; do
        zc_pattern="zero_crossing.hmirun${RUN_NUMBER}rev6newrr.*.${var}.asym.out"

        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "[WOULD CHECK] ${HOST_ZEROCROSS_DIR}/${zc_pattern}"
            PASS_COUNT=$((PASS_COUNT + 1))
            continue
        fi

        zc_count=$(find "$HOST_ZEROCROSS_DIR" -maxdepth 1 -name "$zc_pattern" 2>/dev/null | wc -l)
        zc_count=$(echo "$zc_count" | tr -d '[:space:]')

        if [[ "$zc_count" -ge 1 ]]; then
            log_info "[OK] ${var}: found"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            log_error "[MISSING] ${var}: not found in ${HOST_ZEROCROSS_DIR}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    if [[ $FAIL_COUNT -gt 0 ]]; then
        log_error "${FAIL_COUNT}/13 zero crossing files missing"
        exit 1
    fi
    log_info "All 13 zero crossing files verified!"

    save_checkpoint "verify"
fi

# ==============================================================================
# STEP 6: 2aves case
# ==============================================================================
banner "Step 6: Run 2aves (and 4aves, 6aves) case"

if ! should_skip "aves"; then
    sing_exec "preptranszero avgonly for Run ${RUN_NUMBER}" \
        "cd ${CONT_SCRIPTS_DIR} && ./preptranszerohmiwtrev6rr-dp-avgonly.sh ${RUN_NUMBER}"

    save_checkpoint "aves"
fi

# ==============================================================================
# Summary
# ==============================================================================
banner "Part 6 Summary"
log_info "Part 6 (Regression and Transposition) completed for Run ${RUN_NUMBER}"
clear_checkpoint
log_info ""
log_info "Run ${RUN_NUMBER} pipeline is COMPLETE!"
log_info ""
log_info "Zero crossing results in:"
log_info "  ${HOST_ZEROCROSS_DIR}/zero_crossing.hmirun${RUN_NUMBER}rev6newrr.*.asym.out"
