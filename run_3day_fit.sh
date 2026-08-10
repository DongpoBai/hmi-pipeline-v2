#!/bin/bash
# ==============================================================================
# run_3day_fit.sh -- Part 3: Fitting (3-day HMI power spectra pipeline)
#
# Wraps the official Part 3 flow (3-day instructions, pages 13-16):
#   1. convertpwintowf_hmiRR.sh RR         (in container) pwin -> wf (3day+72day)
#   2. prepfitwtrev6rr.disc.slurm.sh ...   (in container) generate 24 fit dirs
#   3. fix_legacy_slurm.sh --part fit      (host) patch generated SLURM/srun
#   4. qsubfitjob<dr>...rev6.slurm.sh 0 0  (host) submit 1 SLURM job / daterange
#   5. wait for all jobs, then verify      8 H*errfp.gz + 0 H*failed.gz per dr
#
# Scope: this wrapper covers the DETERMINISTIC flow only. The manual polishing
# loop for stubborn/failed modes (checkCoverage.sh, seed recomputation, 9999
# resubmission -- instructions pages 15-16) is NOT automated; it is an
# interactive debugging procedure invoked when verification reports failures.
# The wrapper reports which dateranges failed so the operator can polish them.
#
# Usage:
#   ./run_3day_fit.sh --run 81 --dry-run          # preview every step
#   ./run_3day_fit.sh --run 81 --test-container   # verify container exec
#   ./run_3day_fit.sh --run 81                     # submit + wait + verify
#   ./run_3day_fit.sh --run 81 --resume            # re-attach to running jobs
#   ./run_3day_fit.sh --run 81 --validate          # only check existing output
#
# Env knobs (paths/behavior go via env, not config -- shared convention):
#   FIT_WAIT=false      submit and exit without blocking (check later with --validate)
#   FIT_TIMEOUT=54000   per-job wait timeout in seconds (default 15 h)
#   QSUBFIT_ARGS="0 0"  args passed to qsubfitjob. Use "-h 0 0" ONLY if the
#                       spectra were renormalized on HPCC old disk (see p.14).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Standard wrapper bootstrap (identical to run_3day_convsub.sh) ─────────────
parse_common_args "$@"
init_pipeline "part3_fit" "$RUN_NUMBER"
load_config "$CONFIG_FILE"

# ── Config-derived paths ─────────────────────────────────────────────────────
# PROJECT_BASE is set as an env default in common.sh (line 30); this fallback is
# redundant but harmless. /home/rcf-XX inside the container maps to this.
PROJECT_BASE="${PROJECT_BASE:-/project2/erhodes_44}"

# Container working dir for the two prep steps (sing_exec binds /home).
CONT_THEOR="/home/rcf-04/astro10/wmltp/theor1.0"
# Host-side equivalents for verification / submission (outside container).
THEOR_HOST="${PROJECT_BASE}/rcf-04/astro10/wmltp/theor1.0"
WINDOW_HOST="${PROJECT_BASE}/rcf-04/astro10/windowtest/HMIrun${RUN_NUMBER}"
# Fixed fitting subdir. Must match the path hardcoded in fix_legacy_slurm's
# fix_fit(); if a future run uses a different lgc* name, both change together.
LGC_SUBDIR="fdxref61/lgcfnonncorall96b2b4rev6asm"

# Behavior knobs
FIT_WAIT="${FIT_WAIT:-true}"
FIT_TIMEOUT="${FIT_TIMEOUT:-54000}"
QSUBFIT_ARGS="${QSUBFIT_ARGS:-0 0}"

# Persisted job-id list (survives an SSH drop so --resume re-attaches).
JOBID_FILE="${CHECKPOINT_DIR}/fit_jobids.run${RUN_NUMBER}.lst"

# ── Daterange source of truth ────────────────────────────────────────────────
# Copied verbatim from the verified logic in run_3day_mavg.sh (its "Load date
# ranges" block) so Part 3 resolves dateranges identically: config DATE_RANGES
# is the override; otherwise read the genDRlist .lst (with the MDIDNxSETL naming
# fallback), with dry-run placeholders. No main-pipeline file is modified.
RUN_PAD=$(printf '%02d' "$RUN_NUMBER")
HOST_DATA_DIR="${PROJECT_BASE}/rcf-57/astro0/data"

if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
    DR_LIST_FILE="${HOST_DATA_DIR}/run${RUN_PAD}.dateranges.lst"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would read date ranges from: ${DR_LIST_FILE}"
        DATE_RANGES=("DR_PLACEHOLDER_01" "DR_PLACEHOLDER_02" "DR_PLACEHOLDER_03")
        log_dry "Using ${#DATE_RANGES[@]} placeholder date ranges for dry-run"
    else
        if [[ ! -f "$DR_LIST_FILE" ]]; then
            # Alternate naming produced by genDRlist (MDIDN x SETL)
            DR_LIST_FILE="${HOST_DATA_DIR}/${MDIDN}x${SETL}.dateranges.lst"
        fi
        if [[ ! -f "$DR_LIST_FILE" ]]; then
            log_error "Cannot find date range list file. Looked for:"
            log_error "  ${HOST_DATA_DIR}/run${RUN_PAD}.dateranges.lst"
            log_error "  ${HOST_DATA_DIR}/${MDIDN}x${SETL}.dateranges.lst"
            log_error "Please fill DATE_RANGES in the config file, or verify genDRlist ran correctly."
            exit 1
        fi
        log_info "Reading date ranges from: ${DR_LIST_FILE}"
        mapfile -t DATE_RANGES < "$DR_LIST_FILE"
        # Remove stray whitespace and empty lines
        DATE_RANGES=("${DATE_RANGES[@]//[[:space:]]/}")
        DATE_RANGES=($(printf '%s\n' "${DATE_RANGES[@]}" | grep -v '^$'))
    fi
fi

# ── Verification helper (used by the verify step AND by --validate) ───────────
verify_fitting() {
    banner "Verify fitting output (8 H*errfp.gz + 0 H*failed.gz per daterange)"
    local ok=0 bad=0
    local failed_drs=()
    local blocked_drs=()
    # Which dateranges have a fitting job in the queue right now. Queried once:
    # calling squeue per daterange would be 24 calls and invites rate limiting.
    # `|| true` is required: under `set -euo pipefail`, grep returning 1 on an
    # empty queue would abort the whole function, which is the common case.
    local running_drs=""
    running_drs=$(squeue -u "$PIPELINE_USER" -h -o "%j" 2>/dev/null \
        | grep '^fitjob' | sed 's/^fitjob//; s/dpirlnewrr.*//' || true)

    for dr in "${DATE_RANGES[@]}"; do
        local d_dir="${THEOR_HOST}/weightedhmi${dr}dpirlnewrr/${LGC_SUBDIR}/D"

        if [[ ! -d "$d_dir" ]]; then
            log_error "[FAIL] ${dr}: D/ directory missing"
            bad=$((bad + 1)); failed_drs+=("$dr"); continue
        fi

        local gz_n failed_n
        gz_n=$(find "$d_dir" -maxdepth 1 -name 'H*errfp.gz' 2>/dev/null | wc -l)
        failed_n=$(find "$d_dir" -maxdepth 1 -name 'H*failed.gz' 2>/dev/null | wc -l)
        gz_n=$(echo "$gz_n" | tr -d '[:space:]')
        failed_n=$(echo "$failed_n" | tr -d '[:space:]')

        if [[ "$gz_n" -eq 8 && "$failed_n" -eq 0 ]]; then
            log_info "[OK] ${dr}: 8 errfp.gz, 0 failed"
            ok=$((ok + 1))
        else
            # A leftover tD.* blocks every resubmission while still exiting 0, so
            # the job looks COMPLETED and nothing is fitted. Only counts as blocked
            # when no job for this daterange is running: a live fit has tD.* too.
            local td_n
            td_n=$(find "$d_dir" -maxdepth 1 -type d -name 'tD.*' 2>/dev/null | wc -l)
            td_n=$(echo "$td_n" | tr -d '[:space:]')
            if [[ "$td_n" -gt 0 ]] && ! grep -qx "$dr" <<< "$running_drs"; then
                log_error "[BLOCKED] ${dr}: ${td_n} stale tD.* left, errfp.gz=${gz_n}/8"
                bad=$((bad + 1)); blocked_drs+=("$dr")
            else
                log_error "[FAIL] ${dr}: errfp.gz=${gz_n}/8, failed.gz=${failed_n}"
                bad=$((bad + 1)); failed_drs+=("$dr")
            fi
        fi
    done

    log_info "Part 3 fitting: ${ok}/${#DATE_RANGES[@]} dateranges complete"
    if [[ ${#blocked_drs[@]} -gt 0 ]]; then
        log_error "${#blocked_drs[@]} daterange(s) blocked by a stale tempdir: ${blocked_drs[*]}"
        log_error "Nothing was fitted for these. Polishing will not help and"
        log_error "resubmitting as-is returns the same empty result. Clear the"
        log_error "leftovers first: see the manual, appendix on a fit that"
        log_error "finishes in minutes with nothing to show."
    fi
    if [[ ${#failed_drs[@]} -gt 0 ]]; then
        log_error "${#failed_drs[@]} daterange(s) need manual polishing: ${failed_drs[*]}"
        log_error "See 3-day instructions p.15-16: checkCoverage.sh, recompute"
        log_error "seeds for wallclock-breaking modes, resubmit with set=9999."
    fi
    if [[ $bad -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ── --validate: check existing output only, execute nothing ──────────────────
if [[ "${VALIDATE:-false}" == "true" ]]; then
    verify_fitting
    exit $?
fi

# ── --test-container: prove sing_exec works, then stop ───────────────────────
if [[ "${TEST_CONTAINER:-false}" == "true" ]]; then
    run_container_test
    exit $?
fi

# ── Step ordering for checkpoint/resume ──────────────────────────────────────
STEP_ORDER=(convpwin prepfit fix_slurm submit wait verify)

RESUME_STEP=""
if [[ "$RESUME" == "true" ]] && load_checkpoint; then
    RESUME_STEP="$CHECKPOINT_STEP"
    log_info "Resuming from checkpoint: ${RESUME_STEP}"
fi

# ==============================================================================
# STEP 1: Convert pwin -> wf  (does both 3-day and 72-day)
# ==============================================================================
banner "Step 1: Convert pwin to wf (convertpwintowf)"

if ! should_skip "convpwin"; then
    sing_exec "convertpwintowf for Run ${RUN_NUMBER}" \
        "cd ${CONT_THEOR} && ./convertpwintowf_hmiRR.sh ${RUN_NUMBER}"

    if [[ "$DRY_RUN" != "true" ]]; then
        wf_n=$(find "$WINDOW_HOST" -maxdepth 1 -name 'wfhmi.*' 2>/dev/null | wc -l)
        wf_n=$(echo "$wf_n" | tr -d '[:space:]')
        log_info "wf files in HMIrun${RUN_NUMBER}: ${wf_n} (expect ~25: 24 dateranges + 72-day)"
        if [[ "$wf_n" -lt "${#DATE_RANGES[@]}" ]]; then
            log_error "Too few wf files (${wf_n} < ${#DATE_RANGES[@]}). Check convertpwintowf output."
            exit 1
        fi
    fi

    save_checkpoint "convpwin"
fi

# ==============================================================================
# STEP 2: Generate the 24 daterange fitting directories + submit scripts
# ==============================================================================
banner "Step 2: Generate fitting scripts (prepfitwtrev6rr)"

if ! should_skip "prepfit"; then
    # Args per instructions p.14: MDIDN <inst> 3 <n_dateranges>
    sing_exec "prepfit for MDIDN=${MDIDN}" \
        "cd ${CONT_THEOR} && ./prepfitwtrev6rr.disc.slurm.sh ${MDIDN} ${INSTRUMENT} 3 ${#DATE_RANGES[@]}"

    if [[ "$DRY_RUN" != "true" ]]; then
        dir_n=0
        for dr in "${DATE_RANGES[@]}"; do
            [[ -d "${THEOR_HOST}/weightedhmi${dr}dpirlnewrr/${LGC_SUBDIR}" ]] && dir_n=$((dir_n + 1))
        done
        log_info "Fitting directories present: ${dir_n}/${#DATE_RANGES[@]}"
        if [[ "$dir_n" -ne "${#DATE_RANGES[@]}" ]]; then
            log_error "prepfit did not populate all daterange directories."
            exit 1
        fi
    fi

    save_checkpoint "prepfit"
fi

# ==============================================================================
# STEP 3: Patch generated SLURM/srun files (bind mounts, /project2, module load)
# ==============================================================================
banner "Step 3: Patch legacy SLURM files (fix_legacy_slurm --part fit)"

if ! should_skip "fix_slurm"; then
    # Host-side, dry-run-aware. fix_legacy_slurm is a standalone process (it
    # sources common.sh and parses its own --run/--part) -- call it, do not
    # source it. Pass --dry-run through so its would-fix list shows in previews.
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd "fix_legacy_slurm (fit) for Run ${RUN_NUMBER}" \
            "${SCRIPT_DIR}/fix_legacy_slurm.sh" --run "${RUN_NUMBER}" --part fit --dry-run
    else
        run_cmd "fix_legacy_slurm (fit) for Run ${RUN_NUMBER}" \
            "${SCRIPT_DIR}/fix_legacy_slurm.sh" --run "${RUN_NUMBER}" --part fit
    fi

    save_checkpoint "fix_slurm"
fi

# ==============================================================================
# STEP 4: Submit one fitting job per daterange (outside container)
# ==============================================================================
banner "Step 4: Submit fitting jobs (qsubfitjob ${QSUBFIT_ARGS})"

if ! should_skip "submit"; then
    # Snapshot our queued jobs before submitting so we can identify exactly the
    # ones we launch (robust: does not depend on qsubfitjob's stdout format).
    _pre=()
    if [[ "$DRY_RUN" != "true" ]]; then
        mapfile -t _pre < <(squeue -h -u "${USER}" -o "%i" 2>/dev/null | sort || true)
    fi

    for dr in "${DATE_RANGES[@]}"; do
        sub_dir="${THEOR_HOST}/weightedhmi${dr}dpirlnewrr/${LGC_SUBDIR}"
        qsub_script="qsubfitjob${dr}dpirlnewrr.rev6.slurm.sh"
        run_cmd "submit fitting ${dr}" \
            bash -c "cd '${sub_dir}' && ./${qsub_script} ${QSUBFIT_ARGS}"
    done

    # Record the new job ids for the wait step / --resume re-attach.
    if [[ "$DRY_RUN" != "true" ]]; then
        mapfile -t _post < <(squeue -h -u "${USER}" -o "%i" 2>/dev/null | sort || true)
        comm -13 <(printf '%s\n' "${_pre[@]}") <(printf '%s\n' "${_post[@]}") > "$JOBID_FILE"
        n_new=$(wc -l < "$JOBID_FILE" | tr -d '[:space:]')
        log_info "Submitted ${n_new} new job(s); ids saved to ${JOBID_FILE}"
        if [[ "$n_new" -ne "${#DATE_RANGES[@]}" ]]; then
            log_warn "Expected ${#DATE_RANGES[@]} new jobs but saw ${n_new}."
            log_warn "If other jobs of yours started concurrently, edit ${JOBID_FILE}."
        fi
    fi

    save_checkpoint "submit"
fi

# ==============================================================================
# STEP 5: Wait for all fitting jobs (each < 12 h; run in screen)
# ==============================================================================
banner "Step 5: Wait for fitting jobs to finish"

if ! should_skip "wait"; then
    if [[ "$FIT_WAIT" != "true" ]]; then
        log_info "FIT_WAIT=false -> not blocking. Jobs are running detached."
        log_info "Check later with: ./run_3day_fit.sh --run ${RUN_NUMBER} --validate"
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD WAIT] on jobs in ${JOBID_FILE} (timeout ${FIT_TIMEOUT}s each)"
    else
        if [[ ! -s "$JOBID_FILE" ]]; then
            log_error "No job-id file at ${JOBID_FILE}. Cannot wait. Use --validate later."
            exit 1
        fi
        log_info "Waiting on $(wc -l < "$JOBID_FILE" | tr -d '[:space:]') jobs."
        log_info "Each fitting job takes up to ~12 h -- run this inside screen/nohup."
        while read -r jid; do
            [[ -z "$jid" ]] && continue
            log_info "Waiting for job ${jid}..."
            slurm_wait "$jid" "$FIT_TIMEOUT" || log_warn "Job ${jid} did not complete cleanly; verify below."
        done < "$JOBID_FILE"
    fi

    save_checkpoint "wait"
fi

# ==============================================================================
# STEP 6: Verify output
# ==============================================================================
if ! should_skip "verify"; then
    if [[ "$DRY_RUN" == "true" ]]; then
        banner "Step 6: Verify fitting output"
        log_dry "[WOULD CHECK] 8 H*errfp.gz + 0 H*failed.gz for each of ${#DATE_RANGES[@]} dateranges"
    elif [[ "$FIT_WAIT" != "true" ]]; then
        log_info "Skipping verification (jobs still running under FIT_WAIT=false)."
    else
        verify_fitting || {
            log_error "Fitting incomplete. Polish the failed dateranges, then re-run --validate."
            exit 1
        }
    fi
    save_checkpoint "verify"
fi

# ==============================================================================
# Summary
# ==============================================================================
banner "Part 3 Summary"
log_info "Part 3 (Fitting) flow complete for Run ${RUN_NUMBER}"
clear_checkpoint
log_info ""
log_info "Next step: Part 4 (Conversion and Subtraction)"
log_info "  ./run_3day_convsub.sh --run ${RUN_NUMBER}"