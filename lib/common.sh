#!/bin/bash
# ==============================================================================
# common.sh — Shared function library for pipeline-v2
#
# Usage: source /path/to/lib/common.sh
#
# Provides: logging, dry-run execution, SLURM job waiting, Singularity
#           container execution, file count validation, checkpoint management,
#           and manual pause prompts.
# ==============================================================================

# Exit on error, undefined vars, pipe failures
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Global defaults (can be overridden before sourcing or via CLI flags)
# ──────────────────────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
RESUME="${RESUME:-false}"
VERBOSE="${VERBOSE:-false}"
VALIDATE="${VALIDATE:-false}"
TEST_CONTAINER="${TEST_CONTAINER:-false}"
LOG_DIR="${LOG_DIR:-}"
LOG_FILE="${LOG_FILE:-}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-}"
CHECKPOINT_FILE="${CHECKPOINT_FILE:-}"

# Container configuration
CONTAINER_IMAGE="${CONTAINER_IMAGE:-/project2/erhodes_44/rcf-04/astro10/singularity/images/spscratch/restore_centos7.2405291154.sif_03_06_2025}"
PROJECT_BASE="${PROJECT_BASE:-/project2/erhodes_44}"

# ── Scratch file system ──────────────────────────────────────────────────────
# SCRATCH_MOUNT : which scratch file system this pipeline WRITES to.
#                 Change this default when /scratch1 is retired.
# SCRATCH_BASE  : this operator's directory on it. Derived from $USER so that
#                 no username is ever hardcoded. Override via environment.
# $USER is not guaranteed to be set under `set -u` (e.g. inside SLURM jobs),
# so fall back to id -un.
PIPELINE_USER="${PIPELINE_USER:-${USER:-$(id -un)}}"
SCRATCH_MOUNT="${SCRATCH_MOUNT:-/scratch1}"
SCRATCH_BASE="${SCRATCH_BASE:-${SCRATCH_MOUNT}/${PIPELINE_USER}}"

# Which scratch file systems must be VISIBLE inside the container. This is an
# access question, distinct from SCRATCH_MOUNT above: during the
# /scratch1 -> /scratch2 transition both exist, legacy scripts still reference
# /scratch1, and new data may live on /scratch2. Bind whichever are present so
# that both resolve; the list self-narrows once a file system is retired.
SCRATCH_CANDIDATES=(/scratch1 /scratch2)

get_sing_binds() {
    local binds="--bind ${PROJECT_BASE}:/home"
    binds+=" --bind ${PROJECT_BASE}/rcf-57:/rcf-57"
    binds+=" --bind ${PROJECT_BASE}/rcf-04:/rcf-04"
    binds+=" --bind ${PROJECT_BASE}/rcf-93:/rcf-93"
    local _m
    for _m in "${SCRATCH_CANDIDATES[@]}"; do
        [[ -d "$_m" ]] && binds+=" --bind ${_m}:${_m}"
    done
    echo "$binds"
}


# GSL library path for the Fortran programs that link it (some Part 4/6 steps).
# This points at the container's OWN GSL under /usr/lib64. The previous value was
# a host spack path that does not exist inside the container, so every --ifort
# call exported a dead path. /usr/lib64 is where the container actually ships
# libgsl.so, and is the same GSL build_cycle2423.sh links against.
IFORT_LIB="/usr/lib64"

# SLURM wait defaults
SLURM_POLL_INTERVAL="${SLURM_POLL_INTERVAL:-30}"   # seconds between polls
SLURM_TIMEOUT="${SLURM_TIMEOUT:-14400}"             # 4 hours default timeout

# ──────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────

_log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[${timestamp}] [${level}] $*"

    # Always print to stdout
    case "$level" in
        ERROR) echo -e "\033[31m${msg}\033[0m" ;;
        WARN)  echo -e "\033[33m${msg}\033[0m" ;;
        INFO)  echo -e "\033[32m${msg}\033[0m" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "\033[36m${msg}\033[0m" ;;
        DRY)   echo -e "\033[35m${msg}\033[0m" ;;
    esac

    # Also write to log file if set
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { _log DEBUG "$@"; }
log_dry()   { _log DRY   "$@"; }

# ──────────────────────────────────────────────────────────────────────────────
# Initialization
# ──────────────────────────────────────────────────────────────────────────────

# Call this at the start of each wrapper script.
# Usage: init_pipeline PART_NAME RUN_NUMBER
#   e.g. init_pipeline "part2_mavg" "74"
init_pipeline() {
    local part_name="$1"
    local run_number="$2"

    # Determine script directory (where pipeline-v2 lives)
    PIPELINE_DIR="${PIPELINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
    LOG_DIR="${LOG_DIR:-${PIPELINE_DIR}/logs}"
    CHECKPOINT_DIR="${CHECKPOINT_DIR:-${PIPELINE_DIR}/checkpoints}"

    mkdir -p "$LOG_DIR" "$CHECKPOINT_DIR"

    # Create log file with timestamp
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    LOG_FILE="${LOG_DIR}/run${run_number}_${part_name}_${ts}.log"

    # Checkpoint file (no timestamp — one per run+part)
    CHECKPOINT_FILE="${CHECKPOINT_DIR}/run${run_number}_${part_name}.checkpoint"

    log_info "=========================================="
    log_info "Pipeline v2 — ${part_name} — Run ${run_number}"
    log_info "=========================================="
    log_info "Log file: ${LOG_FILE}"
    log_info "Dry-run: ${DRY_RUN}"
    log_info "Validate-only: ${VALIDATE}"
    log_info "Resume: ${RESUME}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "*** DRY-RUN MODE: No commands will be executed ***"
    fi
    if [[ "$VALIDATE" == "true" ]]; then
        log_info "*** VALIDATE MODE: Only checking existing outputs, no execution ***"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Configuration loading
# ──────────────────────────────────────────────────────────────────────────────

# Load a run configuration file.
# Usage: load_config /path/to/run74.conf
load_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: ${config_file}"
        exit 1
    fi
    log_info "Loading config: ${config_file}"
    # shellcheck source=/dev/null
    source "$config_file"

    # Validate required variables
    local required_vars=(RUN_NUMBER MDIDN SETL INSTRUMENT)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable ${var} not set in config file"
            exit 1
        fi
    done

    # Format run number with leading zero for scripts that need it
    RUN_NUMBER_PAD=$(printf "%02d" "$RUN_NUMBER")

    log_info "Run: ${RUN_NUMBER} (padded: ${RUN_NUMBER_PAD}), MDIDN: ${MDIDN}, SETL: ${SETL}, Instrument: ${INSTRUMENT}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Dry-run aware execution
# ──────────────────────────────────────────────────────────────────────────────

# Execute a command, or just print it in dry-run mode.
# Usage: run_cmd "description" command arg1 arg2 ...
run_cmd() {
    local desc="$1"
    shift

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD RUN] ${desc}"
        log_dry "  Command: $*"
        return 0
    fi

    log_info "${desc}"
    log_debug "  Command: $*"

    if "$@"; then
        log_info "  -> Success"
        return 0
    else
        local rc=$?
        log_error "  -> FAILED (exit code ${rc}): $*"
        return $rc
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Singularity container execution
# ──────────────────────────────────────────────────────────────────────────────

# Execute a command inside the Singularity container.
# The command string is run via /bin/bash -c "..." inside the container.
# Automatically sets up LD_LIBRARY_PATH for ifort if needed.
#
# Usage: sing_exec "description" "cd /home/rcf-57/astro0/data && ./some_script.sh 74"
# Usage: sing_exec --ifort "description" "cd /home/... && ./script_needing_ifort.sh"
sing_exec() {
    local need_ifort=false
    if [[ "$1" == "--ifort" ]]; then
        need_ifort=true
        shift
    fi

    local desc="$1"
    local cmd="$2"

    # Prepend ifort library path if needed
    if [[ "$need_ifort" == "true" ]]; then
        cmd="export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:-}:${IFORT_LIB} && ${cmd}"
    fi

    cmd="export PREPATH=/home && ${cmd}"
    # Single source of truth for bind mounts (incl. the testenv production mount)
    local binds
    binds=$(get_sing_binds)

    local full_cmd="singularity exec ${binds} ${CONTAINER_IMAGE} /bin/bash -c '${cmd}'"


    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD RUN IN CONTAINER] ${desc}"
        log_dry "  Command: ${cmd}"
        return 0
    fi

    log_info "[CONTAINER] ${desc}"
    log_debug "  Full command: ${full_cmd}"

    if eval "$full_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "  -> Success"
        return 0
    else
        local rc=${PIPESTATUS[0]}
        log_error "  -> FAILED (exit code ${rc})"
        return $rc
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SLURM job management
# ──────────────────────────────────────────────────────────────────────────────

# Submit a SLURM job and return the job ID.
# Usage: job_id=$(slurm_submit "description" sbatch script.slurm)
slurm_submit() {
    local desc="$1"
    shift

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD SUBMIT] ${desc}"
        log_dry "  Command: $*"
        echo "DRY_RUN_JOB_ID"
        return 0
    fi

    log_info "[SLURM SUBMIT] ${desc}"
    local output
    output=$("$@" 2>&1) || {
        log_error "sbatch failed: ${output}"
        return 1
    }

    # Parse job ID from "Submitted batch job 12345"
    local job_id
    job_id=$(echo "$output" | grep -oP 'Submitted batch job \K[0-9]+')

    if [[ -z "$job_id" ]]; then
        log_error "Could not parse job ID from sbatch output: ${output}"
        return 1
    fi

    log_info "  -> Submitted job ${job_id}"
    echo "$job_id"
}

# Wait for a SLURM job to complete.
# Usage: slurm_wait JOB_ID [TIMEOUT_SECONDS]
slurm_wait() {
    local job_id="$1"
    local timeout="${2:-$SLURM_TIMEOUT}"
 
    if [[ "$DRY_RUN" == "true" || "$job_id" == "DRY_RUN_JOB_ID" ]]; then
        log_dry "[WOULD WAIT] for SLURM job ${job_id}"
        return 0
    fi
 
    log_info "[SLURM WAIT] Waiting for job ${job_id} (timeout: ${timeout}s, poll: ${SLURM_POLL_INTERVAL}s)"
 
    # Initial delay — give SLURM time to register the job before first check
    sleep 5
 
    local elapsed=5
    local sacct_retries=0
    local max_sacct_retries=6  # 6 retries × 10s = 60s max wait for sacct
 
    while true; do
        # Check if job is still in queue
        local state
        state=$(squeue -j "$job_id" -h -o "%T" 2>/dev/null || echo "GONE")
 
        if [[ "$state" == "GONE" || -z "$state" ]]; then
            # Job no longer in queue — check if it completed successfully via sacct
            local exit_info
            exit_info=$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | head -1 | tr -d '[:space:]')
 
            case "$exit_info" in
                COMPLETED)
                    log_info "  -> Job ${job_id} COMPLETED (elapsed: ${elapsed}s)"
                    return 0
                    ;;
                FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL)
                    log_error "  -> Job ${job_id} ended with state: ${exit_info}"
                    return 1
                    ;;
                "")
                    # sacct doesn't have info yet — retry instead of assuming success
                    sacct_retries=$((sacct_retries + 1))
                    if [[ $sacct_retries -ge $max_sacct_retries ]]; then
                        log_warn "  -> Job ${job_id} not in squeue or sacct after ${max_sacct_retries} retries. Assuming completed."
                        return 0
                    fi
                    log_debug "  Job ${job_id}: not in squeue, sacct empty (retry ${sacct_retries}/${max_sacct_retries})"
                    sleep 10
                    elapsed=$((elapsed + 10))
                    continue
                    ;;
                *)
                    log_warn "  -> Job ${job_id} ended with unexpected state: ${exit_info}"
                    return 1
                    ;;
            esac
        fi
 
        # Reset sacct retries if job is still in queue
        sacct_retries=0
 
        log_debug "  Job ${job_id}: state=${state}, elapsed=${elapsed}s"
 
        if [[ $elapsed -ge $timeout ]]; then
            log_error "  -> TIMEOUT waiting for job ${job_id} after ${timeout}s"
            return 1
        fi
 
        sleep "$SLURM_POLL_INTERVAL"
        elapsed=$((elapsed + SLURM_POLL_INTERVAL))
    done
}


# Convenience: submit and wait in one call.
# Usage: slurm_submit_and_wait "description" sbatch script.slurm [TIMEOUT]
slurm_submit_and_wait() {
    local desc="$1"
    shift

    # Check if last arg is a number (timeout)
    local timeout="$SLURM_TIMEOUT"
    local args=("$@")
    local last_idx=$(( ${#args[@]} - 1 ))
    if [[ "${args[$last_idx]}" =~ ^[0-9]+$ && ${#args[@]} -gt 1 ]]; then
        timeout="${args[$last_idx]}"
        unset 'args[$last_idx]'
    fi

    local job_id
    job_id=$(slurm_submit "$desc" "${args[@]}") || return 1
    slurm_wait "$job_id" "$timeout" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# File count validation
# ──────────────────────────────────────────────────────────────────────────────

# Check that a directory contains the expected number of files matching a pattern.
# Usage: check_file_count "description" /path/to/dir "Y*aspc2nonavdisc" 1001
check_file_count() {
    local desc="$1"
    local dir="$2"
    local pattern="$3"
    local expected="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD CHECK] ${desc}: ${dir}/${pattern} == ${expected}"
        return 0
    fi

    local actual
    # Use find to avoid glob expansion issues with large directories
    actual=$(find "$dir" -maxdepth 1 -name "$pattern" 2>/dev/null | wc -l)
    actual=$(echo "$actual" | tr -d '[:space:]')

    if [[ "$actual" -eq "$expected" ]]; then
        log_info "[CHECK OK] ${desc}: found ${actual}/${expected} files"
        return 0
    else
        log_error "[CHECK FAILED] ${desc}: found ${actual}/${expected} files in ${dir}"
        return 1
    fi
}

# Same as above but runs inside the container (for paths like /home/rcf-57/...)
# Usage: check_file_count_sing "description" /home/rcf-57/path "Y*aspc2nonavdisc" 1001
check_file_count_sing() {
    local desc="$1"
    local dir="$2"
    local pattern="$3"
    local expected="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD CHECK IN CONTAINER] ${desc}: ${dir}/${pattern} == ${expected}"
        return 0
    fi

    local actual
    actual=$(singularity exec $(get_sing_binds) "$CONTAINER_IMAGE" \
        /bin/bash -c "ls ${dir}/${pattern} 2>/dev/null | wc -l")
    actual=$(echo "$actual" | tr -d '[:space:]')

    if [[ "$actual" -eq "$expected" ]]; then
        log_info "[CHECK OK] ${desc}: found ${actual}/${expected} files"
        return 0
    else
        log_error "[CHECK FAILED] ${desc}: found ${actual}/${expected} files in ${dir}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Checkpoint management
# ──────────────────────────────────────────────────────────────────────────────

# Save a checkpoint. Call after each major step completes.
# Usage: save_checkpoint "step_name" ["extra_key=value" ...]
save_checkpoint() {
    local step="$1"
    shift

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD SAVE CHECKPOINT] step=${step} $*"
        return 0
    fi

    {
        echo "CHECKPOINT_STEP=${step}"
        echo "CHECKPOINT_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
        for kv in "$@"; do
            echo "$kv"
        done
    } > "$CHECKPOINT_FILE"

    log_info "[CHECKPOINT] Saved: step=${step}"
}

# Load checkpoint. Returns 0 if checkpoint exists, 1 if not.
# After calling, CHECKPOINT_STEP (and any extra vars) will be set.
# Usage:
#   if load_checkpoint; then
#       echo "Resuming from step: $CHECKPOINT_STEP"
#   fi
load_checkpoint() {
    CHECKPOINT_STEP=""
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CHECKPOINT_FILE"
        log_info "[CHECKPOINT] Loaded: step=${CHECKPOINT_STEP}"
        return 0
    fi
    return 1
}

# Check if a step should be skipped (because checkpoint is past it).
# Usage: should_skip "step_name" && { log_info "Skipping..."; continue; }
#
# Requires a global STEP_ORDER array to be defined, e.g.:
#   STEP_ORDER=(gendrlist mkdir prepmavg pwin updatewindow loop_start)
should_skip() {
    local target_step="$1"

    if [[ "$RESUME" != "true" || -z "${CHECKPOINT_STEP:-}" ]]; then
        return 1  # Not resuming, don't skip
    fi

    # Find indices
    local checkpoint_idx=-1
    local target_idx=-1
    for i in "${!STEP_ORDER[@]}"; do
        [[ "${STEP_ORDER[$i]}" == "$CHECKPOINT_STEP" ]] && checkpoint_idx=$i
        [[ "${STEP_ORDER[$i]}" == "$target_step" ]] && target_idx=$i
    done

    if [[ $target_idx -le $checkpoint_idx ]]; then
        log_info "[SKIP] Step '${target_step}' already completed (checkpoint: '${CHECKPOINT_STEP}')"
        return 0  # Should skip
    fi

    return 1  # Don't skip
}

# Clear checkpoint (call at successful end of wrapper).
clear_checkpoint() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        rm -f "$CHECKPOINT_FILE"
        log_info "[CHECKPOINT] Cleared"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Manual pause
# ──────────────────────────────────────────────────────────────────────────────

# Pause execution and display instructions for a manual step.
# Usage: pause_for_manual "Step description" "Detailed instructions..."
pause_for_manual() {
    local title="$1"
    local instructions="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "[WOULD PAUSE] ${title}"
        log_dry "${instructions}"
        return 0
    fi

    echo ""
    echo "=================================================================="
    echo "  MANUAL STEP REQUIRED: ${title}"
    echo "=================================================================="
    echo ""
    echo "${instructions}"
    echo ""
    read -r -p "Press ENTER when you have completed this step (or Ctrl+C to abort)..."
    echo ""
    log_info "[MANUAL] User confirmed completion of: ${title}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI argument parsing helper
# ──────────────────────────────────────────────────────────────────────────────

# Parse common flags: --dry-run, --resume, --verbose, --validate, --test-container, --run RR, --config FILE
# Usage: parse_common_args "$@"
#   Sets: DRY_RUN, RESUME, VERBOSE, VALIDATE, TEST_CONTAINER, RUN_NUMBER, CONFIG_FILE
parse_common_args() {
    CONFIG_FILE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)        DRY_RUN=true; shift ;;
            --resume)         RESUME=true; shift ;;
            --verbose)        VERBOSE=true; shift ;;
            --validate)       VALIDATE=true; shift ;;
            --test-container) TEST_CONTAINER=true; shift ;;
            --run)            RUN_NUMBER="$2"; shift 2 ;;
            --config)         CONFIG_FILE="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $(basename "$0") --run RR [--config FILE] [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --run RR          Run number (required)"
                echo "  --config FILE     Config file (default: config/runRR.conf)"
                echo "  --dry-run         Print commands without executing"
                echo "  --validate        Only check existing output file counts (no execution)"
                echo "  --test-container  Test that Singularity exec works, then exit"
                echo "  --resume          Resume from last checkpoint"
                echo "  --verbose         Show debug-level messages"
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    # Require --run
    if [[ -z "${RUN_NUMBER:-}" ]]; then
        log_error "Missing required argument: --run RR"
        exit 1
    fi

    # Default config file
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="${PIPELINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}/config/run${RUN_NUMBER}.conf"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Container test
# ──────────────────────────────────────────────────────────────────────────────

# Run a harmless command inside the container to verify the exec mechanism works.
# Tests: image exists, bind mounts work, basic commands run.
# Usage: run_container_test
run_container_test() {
    banner "Container connectivity test"

    log_info "Testing Singularity exec mechanism..."
    log_info "  Image: ${CONTAINER_IMAGE}"
    log_info "  Binds: $(get_sing_binds)"

    # Test 1: Container image exists
    if [[ ! -f "$CONTAINER_IMAGE" ]]; then
        log_error "Container image not found: ${CONTAINER_IMAGE}"
        return 1
    fi
    log_info "  [1/4] Container image exists: OK"

    # Test 2: Basic exec works
    local test_output
    test_output=$(singularity exec $(get_sing_binds) "$CONTAINER_IMAGE" \
        /bin/bash -c "echo CONTAINER_OK" 2>&1) || {
        log_error "  [2/4] Basic exec FAILED: ${test_output}"
        return 1
    }
    if [[ "$test_output" == *"CONTAINER_OK"* ]]; then
        log_info "  [2/4] Basic exec: OK"
    else
        log_error "  [2/4] Unexpected output: ${test_output}"
        return 1
    fi

    # Test 3: Bind mounts accessible
    test_output=$(singularity exec $(get_sing_binds) "$CONTAINER_IMAGE" \
        /bin/bash -c "ls /home/rcf-57/astro0/data/ > /dev/null 2>&1 && echo BINDS_OK" 2>&1) || true
    if [[ "$test_output" == *"BINDS_OK"* ]]; then
        log_info "  [3/4] Bind mounts (/home/rcf-57): OK"
    else
        log_error "  [3/4] Bind mount /home/rcf-57 NOT accessible"
        return 1
    fi

    # Test 4: ifort library path
    test_output=$(singularity exec $(get_sing_binds) "$CONTAINER_IMAGE" \
        /bin/bash -c "ls ${IFORT_LIB}/libgsl.so > /dev/null 2>&1 && echo IFORT_OK || echo IFORT_MISSING" 2>&1) || true
    if [[ "$test_output" == *"IFORT_OK"* ]]; then
        log_info "  [4/4] ifort/GSL library path: OK"
    else
        log_warn "  [4/4] GSL library not found at ${IFORT_LIB} (Part 2 does not need it; Parts 4/6 do)"
    fi

    log_info ""
    log_info "Container test PASSED. Singularity exec is working correctly."
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Utility functions
# ──────────────────────────────────────────────────────────────────────────────

# Print a section banner for readability.
banner() {
    local msg="$1"
    log_info ""
    log_info "──────────────────────────────────────────"
    log_info "  ${msg}"
    log_info "──────────────────────────────────────────"
}

# Convert container path to host path (for file checks outside container)
container_to_host() {
    local cpath="$1"
    echo "$cpath" | sed "s|^/home/|${PROJECT_BASE}/|; s|^/rcf-|${PROJECT_BASE}/rcf-|"
}

# Confirm before proceeding (for destructive operations)
confirm() {
    local msg="$1"
    read -r -p "${msg} [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}
