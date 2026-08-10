#!/bin/bash
# ==============================================================================
# run_3day_mavg.sh — Part 2: M-Averaging and Renormalization
#
# Wraps the entire Part 2 pipeline for 3-day HMI processing:
#   1. Generate date range lists
#   2. Create directories
#   3. Populate mavg/renorm scripts
#   4. [MANUAL] Run pwin on Stanford
#   5. Update window sum values
#   6. Loop over 24 date ranges: cp000 → mavg → verify → psdr → verify
#
# Usage:
#   ./run_3day_mavg.sh --run 74 --test-container   # Test container first
#   ./run_3day_mavg.sh --run 74 --validate          # Check existing outputs
#   ./run_3day_mavg.sh --run 74 --dry-run            # Preview execution
#   ./run_3day_mavg.sh --run 74                      # Run for real (with safety prompt)
#   ./run_3day_mavg.sh --run 74 --resume             # Resume after failure
#
# Recommended test sequence:
#   1. --dry-run       → verify logic and paths
#   2. --test-container → verify Singularity works
#   3. --validate       → verify completed Run outputs exist
#   4. (real run)       → only on a NEW, unprocessed Run
#
# All original scripts are called untouched. This wrapper only orchestrates.
# ==============================================================================

# Locate ourselves
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$SCRIPT_DIR"

# Source common library
source "${SCRIPT_DIR}/lib/common.sh"

# ── Parse CLI ────────────────────────────────────────────────────────────────
parse_common_args "$@"

# ── Initialize ───────────────────────────────────────────────────────────────
init_pipeline "part2_mavg" "$RUN_NUMBER"
load_config "$CONFIG_FILE"

# ── Key paths (container paths) ──────────────────────────────────────────────
# These are paths as seen inside the container (/home = /project2/erhodes_44)
CONT_DATA_DIR="/home/rcf-57/astro0/data"
CONT_WMLTP_DIR="/home/rcf-04/astro10/wmltp/theor1.0"

# Host equivalents (for file checks outside container)
HOST_DATA_DIR="${PROJECT_BASE}/rcf-57/astro0/data"
HOST_WMLTP_DIR="${PROJECT_BASE}/rcf-04/astro10/wmltp/theor1.0"
HOST_WINDOWTEST_DIR="${PROJECT_BASE}/rcf-04/astro10/windowtest"

# ── Timeouts ─────────────────────────────────────────────────────────────────
MAVG_TIMEOUT="${MAVG_TIMEOUT:-1800}"    # 30 min for mavg
PSDR_TIMEOUT="${PSDR_TIMEOUT:-600}"     # 10 min for psdrenorm

# ==============================================================================
# MODE: --test-container  (run container test and exit)
# ==============================================================================
if [[ "$TEST_CONTAINER" == "true" ]]; then
    run_container_test
    exit $?
fi

# ==============================================================================
# MODE: --validate  (only check existing output files, no execution)
# ==============================================================================
if [[ "$VALIDATE" == "true" ]]; then
    banner "VALIDATE MODE: Checking existing outputs for Run ${RUN_NUMBER}"

    # Load date ranges from config (they must be pre-filled for validate)
    if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
        log_error "DATE_RANGES must be filled in config for --validate mode"
        exit 1
    fi

    NUM_DR=${#DATE_RANGES[@]}
    PASS_COUNT=0
    FAIL_COUNT=0

    # Check pwin files
    PWIN_DIR="${HOST_WINDOWTEST_DIR}/HMIrun${RUN_NUMBER}"
    if [[ -d "$PWIN_DIR" ]]; then
        pwin_count=$(ls "$PWIN_DIR"/pwin.* 2>/dev/null | wc -l)
        pwin_count=$(echo "$pwin_count" | tr -d '[:space:]')
        if [[ "$pwin_count" -eq 26 ]]; then
            log_info "[PWIN] HMIrun${RUN_NUMBER}: ${pwin_count} pwin files (OK)"
        else
            log_warn "[PWIN] HMIrun${RUN_NUMBER}: ${pwin_count} pwin files (expected 26)"
        fi
        bad_mdidn=$(ls "$PWIN_DIR"/pwin.03.* 2>/dev/null | sed 's/.*\.//' \
            | awk -v m="$MDIDN" 'length($1)!=length(m) || $1+0<m+0 || $1+0>m+69' | wc -l)
        bad_mdidn=$(echo "$bad_mdidn" | tr -d '[:space:]')
        if [[ "$bad_mdidn" -gt 0 ]]; then
            log_warn "[PWIN] ${bad_mdidn} pwin.03 file(s) have a truncated or out-of-range MDIDN"
            log_warn "[PWIN] fix with: cd ${HOST_WINDOWTEST_DIR} && ./changMDIDN HMIrun${RUN_NUMBER}"
        fi
    else
        log_warn "[PWIN] Directory not found: ${PWIN_DIR}"
    fi

    # Check each date range
    for dr_idx in "${!DATE_RANGES[@]}"; do
        DR="${DATE_RANGES[$dr_idx]}"
        DR_NUM=$((dr_idx + 1))

        HOST_MAVG_DIR="${HOST_DATA_DIR}/avgspc2880.wtnonavgcorrall.${DR}dpirlnewrr.hpcc"

        if [[ ! -d "$HOST_MAVG_DIR" ]]; then
            log_error "[${DR_NUM}/${NUM_DR}] ${DR}: directory NOT FOUND: ${HOST_MAVG_DIR}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi

        # Count mavg output files
        mavg_count=$(find "$HOST_MAVG_DIR" -maxdepth 1 -name "Y*aspc2nonavdisc" 2>/dev/null | wc -l)
        mavg_count=$(echo "$mavg_count" | tr -d '[:space:]')

        # Count psdrenorm output files
        psdr_count=$(find "$HOST_MAVG_DIR" -maxdepth 1 -name "Y*cspc2nonavdisc" 2>/dev/null | wc -l)
        psdr_count=$(echo "$psdr_count" | tr -d '[:space:]')

        if [[ "$mavg_count" -eq 1001 && "$psdr_count" -eq 1001 ]]; then
            log_info "[${DR_NUM}/${NUM_DR}] ${DR}: mavg=${mavg_count} psdr=${psdr_count} (OK)"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            log_error "[${DR_NUM}/${NUM_DR}] ${DR}: mavg=${mavg_count}/1001 psdr=${psdr_count}/1001 (MISMATCH)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    # Summary
    banner "Validation Summary"
    log_info "Passed: ${PASS_COUNT}/${NUM_DR}"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        log_error "Failed: ${FAIL_COUNT}/${NUM_DR}"
        exit 1
    else
        log_info "All ${NUM_DR} date ranges have complete Part 2 outputs!"
        exit 0
    fi
fi

# ==============================================================================
# EXECUTION MODE: Full pipeline (requires confirmation for production paths)
# ==============================================================================

# Safety check: warn that this will operate on production directories
log_warn "This script will execute commands that write to PRODUCTION directories:"
log_warn "  ${HOST_DATA_DIR}/"
log_warn "  ${HOST_WINDOWTEST_DIR}/"
if [[ "$DRY_RUN" != "true" ]]; then
    confirm "Are you sure you want to proceed with Run ${RUN_NUMBER}?" || {
        log_info "Aborted by user."
        exit 0
    }
fi

# ── Step ordering for checkpoint/resume ──────────────────────────────────────
STEP_ORDER=(
    gendrlist
    scratch_mkdir
    prepmavgrenorm
    fix_slurm
    pwin_manual
    updatewindow
    loop_start
    # Individual date ranges are tracked by index inside the loop
    loop_done
)

# ── Resume handling ──────────────────────────────────────────────────────────
RESUME_DR_INDEX=0
if [[ "$RESUME" == "true" ]] && load_checkpoint; then
    log_info "Resuming from checkpoint: ${CHECKPOINT_STEP}"
    if [[ -n "${CHECKPOINT_DR_INDEX:-}" ]]; then
        RESUME_DR_INDEX=$CHECKPOINT_DR_INDEX
        log_info "Will resume date range loop from index ${RESUME_DR_INDEX}"
    fi
fi

# ==============================================================================
# STEP 1: Generate date range lists
# ==============================================================================
banner "Step 1: Generate date range lists"

if ! should_skip "gendrlist"; then
    sing_exec "genDRlist.hmi.disc.sh ${RUN_NUMBER_PAD}" \
        "cd ${CONT_DATA_DIR} && ./genDRlist.hmi.disc.sh ${RUN_NUMBER_PAD}"

    sing_exec "genDRlist.disc.sh ${MDIDN} ${SETL}" \
        "cd ${CONT_DATA_DIR} && ./genDRlist.disc.sh ${MDIDN} ${SETL}"

    save_checkpoint "gendrlist"
fi

# ── Load date ranges ─────────────────────────────────────────────────────────
# If DATE_RANGES not provided in config, read from the generated .lst file
if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
    DR_LIST_FILE="${HOST_DATA_DIR}/run${RUN_NUMBER_PAD}.dateranges.lst"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would read date ranges from: ${DR_LIST_FILE}"
        # In dry-run, create placeholder date ranges
        DATE_RANGES=("DR_PLACEHOLDER_01" "DR_PLACEHOLDER_02" "DR_PLACEHOLDER_03")
        log_dry "Using ${#DATE_RANGES[@]} placeholder date ranges for dry-run"
    else
        if [[ ! -f "$DR_LIST_FILE" ]]; then
            # Try alternate naming convention
            DR_LIST_FILE="${HOST_DATA_DIR}/${MDIDN}x${SETL}.dateranges.lst"
        fi

        if [[ ! -f "$DR_LIST_FILE" ]]; then
            log_error "Cannot find date range list file. Looked for:"
            log_error "  ${HOST_DATA_DIR}/run${RUN_NUMBER_PAD}.dateranges.lst"
            log_error "  ${HOST_DATA_DIR}/${MDIDN}x${SETL}.dateranges.lst"
            log_error "Please fill DATE_RANGES in the config file, or verify genDRlist ran correctly."
            exit 1
        fi

        log_info "Reading date ranges from: ${DR_LIST_FILE}"
        mapfile -t DATE_RANGES < "$DR_LIST_FILE"
        # Remove empty lines
        DATE_RANGES=("${DATE_RANGES[@]//[[:space:]]/}")
        DATE_RANGES=($(printf '%s\n' "${DATE_RANGES[@]}" | grep -v '^$'))
    fi
fi

NUM_DR=${#DATE_RANGES[@]}
log_info "Date ranges loaded: ${NUM_DR}"
for i in "${!DATE_RANGES[@]}"; do
    log_debug "  [$i] ${DATE_RANGES[$i]}"
done

if [[ $NUM_DR -ne $SETL && "$DRY_RUN" != "true" ]]; then
    log_warn "Expected ${SETL} date ranges but found ${NUM_DR}"
fi

# ==============================================================================
# PREFLIGHT: refuse to overwrite a Run that already has complete Part 2 outputs
# ==============================================================================
# Step 2 (scratch_mkdir) and Step 3 (prepmavgrenorm) rebuild the per-daterange
# directories under HOST_DATA_DIR. They clear the Y*aspc2nonavdisc and
# Y*cspc2nonavdisc products that an earlier pass produced, then repopulate the
# directory with fresh prep scripts. Running them again on a Run whose Part 2 is
# already finished therefore destroys completed output before anything is
# resubmitted. This guard stops the script before Step 2 whenever any date range
# in scope is already complete.
#
# Scope is the DATE_RANGES actually loaded for this invocation, so a per-member
# config is checked only against that member's date ranges. Note that Steps 2
# and 3 themselves operate on the whole Run regardless of DATE_RANGES, which is
# why a single complete date range is enough to refuse.
#
# Skipped for --dry-run, --validate and --resume. Override by setting
# MAVG_FORCE_RERUN=1 on the command line. That variable is deliberately not a
# flag: it is never set by board.sh, by any alias, or by any documented routine
# workflow, so overwriting finished output is always an explicit act.

if [[ "$DRY_RUN" != "true" && "$VALIDATE" != "true" && "$RESUME" != "true" ]]; then
    banner "Preflight: checking for existing Part 2 outputs"

    PF_COUNT=0
    PF_LIST=""
    for pf_idx in "${!DATE_RANGES[@]}"; do
        PF_DR="${DATE_RANGES[$pf_idx]}"
        PF_DIR="${HOST_DATA_DIR}/avgspc2880.wtnonavgcorrall.${PF_DR}dpirlnewrr.hpcc"
        if [[ ! -d "$PF_DIR" ]]; then
            continue
        fi
        pf_mavg=$(find "$PF_DIR" -maxdepth 1 -name "Y*aspc2nonavdisc" 2>/dev/null | wc -l)
        pf_mavg=$(echo "$pf_mavg" | tr -d '[:space:]')
        pf_psdr=$(find "$PF_DIR" -maxdepth 1 -name "Y*cspc2nonavdisc" 2>/dev/null | wc -l)
        pf_psdr=$(echo "$pf_psdr" | tr -d '[:space:]')
        if [[ "$pf_mavg" -eq 1001 && "$pf_psdr" -eq 1001 ]]; then
            PF_COUNT=$((PF_COUNT + 1))
            PF_LIST="${PF_LIST}${PF_DR}"$'\n'
        fi
    done

    if [[ "$PF_COUNT" -eq 0 ]]; then
        log_info "No complete date ranges in scope. Safe to proceed."
    elif [[ "${MAVG_FORCE_RERUN:-0}" == "1" ]]; then
        log_warn "MAVG_FORCE_RERUN=1 is set. Proceeding even though ${PF_COUNT} of ${NUM_DR} date range(s) are already complete."
        while IFS= read -r pf_line; do
            [[ -n "$pf_line" ]] && log_warn "  will be overwritten: ${pf_line}"
        done <<< "$PF_LIST"
    else
        log_error "Refusing to run. ${PF_COUNT} of ${NUM_DR} date range(s) in scope already have complete Part 2 outputs:"
        while IFS= read -r pf_line; do
            [[ -n "$pf_line" ]] && log_error "  complete (mavg 1001, psdr 1001): ${pf_line}"
        done <<< "$PF_LIST"
        log_error "Step 2 and Step 3 would clear these products before any job is submitted."
        log_error "Pick one of:"
        log_error "  $0 --run ${RUN_NUMBER} --validate        inspect without changing anything"
        log_error "  $0 --run ${RUN_NUMBER} --resume          continue an interrupted pass"
        log_error "  MAVG_FORCE_RERUN=1 $0 --run ${RUN_NUMBER} [--config FILE]   overwrite on purpose"
        exit 1
    fi
fi
# ==============================================================================
# STEP 2: Create directories on scratch
# ==============================================================================
banner "Step 2: Create directories (scratch_mkdir)"

if ! should_skip "scratch_mkdir"; then
    sing_exec "scratch_mkdir for Run ${RUN_NUMBER}" \
        "cd ${CONT_DATA_DIR} && ./scratch_mkdir_hmiRR-03d.wtnonavgcorrall.newrr.disc.edit.sh ${RUN_NUMBER}"

    save_checkpoint "scratch_mkdir"
fi

# ==============================================================================
# STEP 3: Populate m-averaging and renormalization scripts
# ==============================================================================
banner "Step 3: Populate mavg/renorm scripts (prepmavgrenorm)"

if ! should_skip "prepmavgrenorm"; then
    sing_exec "prepmavgrenorm for MDIDN=${MDIDN}" \
        "cd ${CONT_DATA_DIR} && ./prepmavgrenorm.wtcorrall.newrr.disc.sh ${MDIDN} ${INSTRUMENT} 3 ${SETL}"

    save_checkpoint "prepmavgrenorm"
fi

# ==============================================================================
# STEP 3.5: Patch generated SLURM files (add container bind mounts)
#
# prepmavgrenorm generates the per-daterange sbatch*.slurm files without bind
# mounts on the current Discovery. fix_legacy_slurm adds them. It is idempotent
# (skips files that already have binds), so it is safe to run every time. This
# must happen before the Step 6 loop submits those SLURM files.
# fix_legacy_slurm is a container-OUTSIDE script, so run_cmd (not sing_exec).
# ==============================================================================
banner "Step 3.5: Patch generated SLURM files (bind mounts)"

if ! should_skip "fix_slurm"; then
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd "fix_legacy_slurm (mavg) for Run ${RUN_NUMBER}" \
            "${SCRIPT_DIR}/fix_legacy_slurm.sh" --run "${RUN_NUMBER}" --part mavg --dry-run
    else
        run_cmd "fix_legacy_slurm (mavg) for Run ${RUN_NUMBER}" \
            "${SCRIPT_DIR}/fix_legacy_slurm.sh" --run "${RUN_NUMBER}" --part mavg
    fi
    save_checkpoint "fix_slurm"
fi

# ==============================================================================
# STEP 4: [MANUAL] Run pwin on Stanford solarport
# ==============================================================================
banner "Step 4: [MANUAL] Window sum values (pwin)"

if ! should_skip "pwin_manual"; then
    # First, ensure the HMIrun## directory exists on RCF
    PWIN_DIR="${HOST_WINDOWTEST_DIR}/HMIrun${RUN_NUMBER}"
    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$PWIN_DIR"
        chgrp erhodes_44 "$PWIN_DIR" 2>/dev/null || true
        chmod g+rw "$PWIN_DIR" 2>/dev/null || true
    fi

    pause_for_manual "Generate window sum values on Stanford" \
"Stanford's pwin.auto.sh no longer works. Its failures look like missing data:
without show_info on the path it reports no records and walks the date
backwards, and with the path fixed it calls IDL, which now runs in demo mode
and cannot write files. Use Stanford only to locate the two gap files, and do
the arithmetic here.

  1. On solar3, find the two gaps.fits paths:
     ssh -X -o ConnectTimeout=15 YOUR_USERNAME@solarport.stanford.edu
     ssh -x solar3.stanford.edu
     export PATH=/home/phil/jsoc/bin/linux_x86_64:\$PATH
     show_info hmi.v_sht_gaps_72d'[${MDIDN}d]'    -AP JSOC_DBUSER=readonlyuser
     show_info hmi.v_sht_gf_gaps_72d'[${MDIDN}d]' -AP JSOC_DBUSER=readonlyuser

     If one has no record, do NOT shift the date to find one. It means JSOC has
     not generated that MDIDN yet. Ask Baldner.

  2. On solarport, rename them apart and send both in one transfer:
     exit                       # back to solarport, NOT solar3
     mkdir -p /tmp/pwin${RUN_NUMBER}
     cp <path1>/gaps.fits /tmp/pwin${RUN_NUMBER}/gaps1_${RUN_NUMBER}.fits
     cp <path2>/gaps.fits /tmp/pwin${RUN_NUMBER}/gaps2_${RUN_NUMBER}.fits
     ls -l /tmp/pwin${RUN_NUMBER}/            # each about 138 KB
     scp /tmp/pwin${RUN_NUMBER}/*.fits \\
         YOUR_USERNAME@hpc-transfer1.usc.edu:/scratch1/YOUR_USERNAME/
     rm -rf /tmp/pwin${RUN_NUMBER}

  3. On Discovery, compute the window sums:
     mkdir -p /scratch1/$USER/pwin${RUN_NUMBER} && cd /scratch1/$USER/pwin${RUN_NUMBER}
     mv /scratch1/$USER/gaps?_${RUN_NUMBER}.fits .
     export OPENBLAS_NUM_THREADS=1
     python3 /project2/erhodes_44/pipeline-v2/pwinauto.py \\
         gaps1_${RUN_NUMBER}.fits gaps2_${RUN_NUMBER}.fits ${MDIDN} 0 72 3 45.0

     Arguments after the two files: MDIDN, offset 0, 72-day span, 3-day step,
     45-second sampling.

  4. Check the names before deploying, not just the count:
     ls pwin.* | wc -l                        # 26
     ls pwin.03.* | sed 's/.*\\.//' | sort | head -3

     You want the full five-digit MDIDN (${MDIDN}), not a four-digit one. A
     leading digit has been dropped before. If it happens:
       cd ${HOST_WINDOWTEST_DIR} && ./changMDIDN HMIrun${RUN_NUMBER}

  5. Deploy:
     mv pwin.* ${PWIN_DIR}/
     chgrp erhodes_44 ${PWIN_DIR}/* 2>/dev/null
     chmod g+rw ${PWIN_DIR}/* 2>/dev/null

Expected: 26 pwin files in ${PWIN_DIR}/
  (24 pwin.03.* + 1 pwin.72.* + 1 pwin.out)
"

    # Verify pwin files
    if [[ "$DRY_RUN" != "true" ]]; then
        pwin_count=$(ls "$PWIN_DIR"/pwin.* 2>/dev/null | wc -l)
        pwin_count=$(echo "$pwin_count" | tr -d '[:space:]')
        if [[ "$pwin_count" -lt 26 ]]; then
            log_warn "Found only ${pwin_count} files in ${PWIN_DIR} (expected 26)"
            log_warn "Continuing anyway — double-check pwin results!"
        else
            log_info "pwin files OK: ${pwin_count} files in ${PWIN_DIR}"
        fi
    fi

    save_checkpoint "pwin_manual"
fi

# ==============================================================================
# STEP 5: Update window sum values in psdr scripts
# ==============================================================================
banner "Step 5: Update window sums (updatewindosum)"

if ! should_skip "updatewindow"; then
    sing_exec "updatewindosum for Run ${RUN_NUMBER}" \
        "cd ${CONT_DATA_DIR} && ./updatewindosum_hmiRR-03d.wtcorrall.newrr.disc.sh ${RUN_NUMBER}"

    save_checkpoint "updatewindow"
fi

# ==============================================================================
# STEP 6: Loop over date ranges — cp000, mavg, psdrenorm
# ==============================================================================
banner "Step 6: Process ${NUM_DR} date ranges (mavg + psdrenorm)"

FAILED_DRS=()
PASS_COUNT=0

for dr_idx in "${!DATE_RANGES[@]}"; do
    DR="${DATE_RANGES[$dr_idx]}"
    DR_NUM=$((dr_idx + 1))

    # Skip already-completed date ranges on resume
    if [[ "$RESUME" == "true" && $dr_idx -lt $RESUME_DR_INDEX ]]; then
        log_info "[${DR_NUM}/${NUM_DR}] Skipping ${DR} (already completed)"
        PASS_COUNT=$((PASS_COUNT + 1))
        continue
    fi

    banner "Date range [${DR_NUM}/${NUM_DR}]: ${DR}"

    # Container path for this date range's mavg directory
    CONT_MAVG_DIR="${CONT_DATA_DIR}/avgspc2880.wtnonavgcorrall.${DR}dpirlnewrr.hpcc"
    # Host path equivalent
    HOST_MAVG_DIR="${HOST_DATA_DIR}/avgspc2880.wtnonavgcorrall.${DR}dpirlnewrr.hpcc"

    # ── 6a: cp000file.sh (inside container) ──────────────────────────────
    log_info "[${DR_NUM}/${NUM_DR}] Running cp000file.sh for ${DR}"
    sing_exec "cp000file.sh for ${DR}" \
        "cd ${CONT_MAVG_DIR} && ./cp000file.sh"

    # ── 6b: Submit m-averaging (outside container) ───────────────────────
    log_info "[${DR_NUM}/${NUM_DR}] Submitting mavg SLURM job for ${DR}"

    MAVG_SLURM="${HOST_MAVG_DIR}/sbatchmavg${DR}.slurm"

    if [[ "$DRY_RUN" != "true" && ! -f "$MAVG_SLURM" ]]; then
        log_error "SLURM script not found: ${MAVG_SLURM}"
        FAILED_DRS+=("${DR}:mavg_slurm_missing")
        continue
    fi

    MAVG_JOB_ID=$(slurm_submit "mavg for ${DR}" sbatch "$MAVG_SLURM") || {
        FAILED_DRS+=("${DR}:mavg_submit_failed")
        continue
    }

    # ── 6c: Wait for m-averaging to complete ─────────────────────────────
    slurm_wait "$MAVG_JOB_ID" "$MAVG_TIMEOUT" || {
        FAILED_DRS+=("${DR}:mavg_job_failed")
        continue
    }

    # ── 6d: Verify m-averaging output (1001 files) ──────────────────────
    check_file_count "mavg output for ${DR}" \
        "$HOST_MAVG_DIR" "Y*aspc2nonavdisc" 1001 || {
        FAILED_DRS+=("${DR}:mavg_count_mismatch")
        continue
    }

    # ── 6e: Submit psdrenormalization (outside container) ────────────────
    log_info "[${DR_NUM}/${NUM_DR}] Submitting psdrenorm SLURM job for ${DR}"

    PSDR_SLURM="${HOST_MAVG_DIR}/sbatchpsdrenorm${DR}.slurm"

    if [[ "$DRY_RUN" != "true" && ! -f "$PSDR_SLURM" ]]; then
        log_error "SLURM script not found: ${PSDR_SLURM}"
        FAILED_DRS+=("${DR}:psdr_slurm_missing")
        continue
    fi

    PSDR_JOB_ID=$(slurm_submit "psdrenorm for ${DR}" sbatch "$PSDR_SLURM") || {
        FAILED_DRS+=("${DR}:psdr_submit_failed")
        continue
    }

    # ── 6f: Wait for psdrenorm to complete ───────────────────────────────
    slurm_wait "$PSDR_JOB_ID" "$PSDR_TIMEOUT" || {
        FAILED_DRS+=("${DR}:psdr_job_failed")
        continue
    }

    # ── 6g: Verify psdrenorm output (1001 files) ────────────────────────
    check_file_count "psdrenorm output for ${DR}" \
        "$HOST_MAVG_DIR" "Y*cspc2nonavdisc" 1001 || {
        FAILED_DRS+=("${DR}:psdr_count_mismatch")
        continue
    }

    # ── 6h: Save checkpoint for this date range ─────────────────────────
    PASS_COUNT=$((PASS_COUNT + 1))
    save_checkpoint "loop_dr" "CHECKPOINT_DR_INDEX=$((dr_idx + 1))"
    log_info "[${DR_NUM}/${NUM_DR}] ${DR} COMPLETE"
done

# ==============================================================================
# Summary
# ==============================================================================
banner "Part 2 Summary"

log_info "Date ranges processed: ${PASS_COUNT}/${NUM_DR}"

if [[ ${#FAILED_DRS[@]} -gt 0 ]]; then
    log_error "FAILURES (${#FAILED_DRS[@]}):"
    for fail in "${FAILED_DRS[@]}"; do
        log_error "  - ${fail}"
    done
    log_error ""
    log_error "To retry failed date ranges, fix the issues and run with --resume"
    exit 1
else
    log_info "All ${NUM_DR} date ranges completed successfully!"
    clear_checkpoint
    log_info ""
    log_info "Next step: Part 3 (Fitting)"
    log_info "  ./run_3day_fit.sh --run ${RUN_NUMBER}"
fi
