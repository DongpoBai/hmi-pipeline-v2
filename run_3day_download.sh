#!/bin/bash
#=============================================================================
# run_3day_download.sh
# Integrated 3-Day HMI Power Spectra Download Pipeline
#
# Usage: ./run_3day_download.sh RUN_NUMBER [OPTIONS]
#   EX:  ./run_3day_download.sh 79
#        ./run_3day_download.sh 79 --skip-convert
#        ./run_3day_download.sh 79 --start 5      (resume from 5th set)
#        ./run_3day_download.sh 79 --dry-run       (show plan without executing)
#
# What it does (for each of the 24 3-day sets in a run):
#   1. Calculates MDI day number and date range
#   2. Creates directory on scratch
#   3. Creates symlink in project HMI directory
#   4. Downloads 1001 FITS files from Stanford JSOC
#   5. Verifies download completeness
#   6. Submits convert_fits SLURM job
#
# Requires: python3 with drms package, NtoD binary
# Recommended: run inside screen session
#=============================================================================

set -euo pipefail

#-----------------------------
# USER CONFIGURATION
#-----------------------------
# Scratch: SCRATCH_MOUNT selects the file system, SCRATCH_BASE the per-user
# directory on it. Both are environment-overridable; no username is hardcoded.
PIPELINE_USER="${PIPELINE_USER:-${USER:-$(id -un)}}"
SCRATCH_MOUNT="${SCRATCH_MOUNT:-/scratch1}"
SCRATCH_BASE="${SCRATCH_BASE:-${SCRATCH_MOUNT}/${PIPELINE_USER}}"
SCRATCH_HMI="${SCRATCH_HMI:-${SCRATCH_BASE}/shared/data/spc/hmi}"

PROJECT_BASE="${PROJECT_BASE:-/project2/erhodes_44}"
PROJECT_HMI="${PROJECT_HMI:-${PROJECT_BASE}/rcf-93/data/spc/hmi}"
NTOD="${NTOD:-${PROJECT_BASE}/rcf-04/astro10/wmltp/theor1.0/scripts/fitsfiles72day/NtoD}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# JSOC export address. MUST already be registered with JSOC or the export is
# rejected. Set JSOC_EMAIL to your own registered address.
EMAIL="${JSOC_EMAIL:-${PIPELINE_USER}@usc.edu}"

# numpy/OpenBLAS tries to start one thread per core and fails to do so on the
# login nodes, which kills every `import drms` downstream. Pin it here, before
# any python in this script runs.
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"

# Run parameters
FIRST_RUN_DAY=6256   # MDI day number of Run 0
DAYS_PER_RUN=72
SETS_PER_RUN=24
DAYS_PER_SET=3

#-----------------------------
# PARSE ARGUMENTS
#-----------------------------
if [ $# -lt 1 ]; then
    echo "Usage: $0 RUN_NUMBER [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --skip-convert   Skip the FITS conversion step (download only)"
    echo "  --start N        Start from the Nth 3-day set (1-24, for resuming)"
    echo "  --end N          End at the Nth 3-day set (1-24)"
    echo "  --dry-run        Show what would be done without executing"
    echo "  --force          Overwrite existing directories/links"
    echo ""
    echo "Examples:"
    echo "  $0 79                    # Full pipeline for Run 79"
    echo "  $0 79 --start 13        # Resume from set 13"
    echo "  $0 79 --dry-run         # Preview only"
    exit 1
fi

RUN=$1
shift

SKIP_CONVERT=false
START_SET=1
END_SET=$SETS_PER_RUN
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-convert) SKIP_CONVERT=true; shift ;;
        --start)        START_SET=$2; shift 2 ;;
        --end)          END_SET=$2; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --force)        FORCE=true; shift ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

#-----------------------------
# SETUP AND VALIDATION
#-----------------------------
LOGDIR="${LOGDIR:-${SCRATCH_BASE}/transfer/logs}"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/run${RUN}_$(date +'%Y%m%d_%H%M%S').log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "============================================"
log "3-Day Download Pipeline - Run $RUN"
log "============================================"

# Validate
if ! command -v python3 &> /dev/null; then
    log "ERROR: python3 not found"; exit 1
fi

if ! _drms_err=$(python3 -c "import drms" 2>&1); then
    log "ERROR: cannot import drms using $(command -v python3)"
    log "Underlying error was:"
    log "${_drms_err}"
    log "If the module is genuinely absent: pip install drms --user"
    log "If it is present but failing to import, this is an environment problem,"
    log "not a missing package -- do not reinstall."
    exit 1
fi

if [ ! -x "$NTOD" ]; then
    log "ERROR: NtoD binary not found at $NTOD"; exit 1
fi

if [ ! -d "$SCRATCH_HMI" ]; then
    log "Creating scratch directory: $SCRATCH_HMI"
    mkdir -p "$SCRATCH_HMI"
fi

# Calculate run parameters
RUN_START_DAY=$(( FIRST_RUN_DAY + RUN * DAYS_PER_RUN ))

log "Run $RUN: MDI start day = $RUN_START_DAY"
log "Processing sets $START_SET to $END_SET of $SETS_PER_RUN"
log "Log file: $LOGFILE"
log ""

#-----------------------------
# BUILD SET TABLE
#-----------------------------
log "--- Plan ---"
for (( i=START_SET; i<=END_SET; i++ )); do
    MDIDN=$(( RUN_START_DAY + (i - 1) * DAYS_PER_SET ))
    DR=$($NTOD $MDIDN)
    DIR="${DR}dpirlrr"
    log "  Set $i/$SETS_PER_RUN: day=$MDIDN  range=$DR  dir=$DIR"
done
log ""

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN: no actions taken."
    exit 0
fi

#-----------------------------
# PROCESS EACH 3-DAY SET
#-----------------------------
SUCCESS=0
FAIL=0
SKIP=0

for (( i=START_SET; i<=END_SET; i++ )); do
    MDIDN=$(( RUN_START_DAY + (i - 1) * DAYS_PER_SET ))
    DR=$($NTOD $MDIDN)
    DIR="${DR}dpirlrr"

    log "========== Set $i/$SETS_PER_RUN: $DR (day $MDIDN) =========="

    # --- Step 1: Create scratch directory ---
    if [ -d "$SCRATCH_HMI/$DIR" ] && [ "$FORCE" = false ]; then
        EXISTING=$(ls "$SCRATCH_HMI/$DIR"/*.fits 2>/dev/null | wc -l)
        if [ "$EXISTING" -eq 1001 ]; then
            log "  SKIP: $DIR already has 1001 FITS files on scratch"
            SKIP=$((SKIP + 1))

            # Still do convert if needed
            if [ "$SKIP_CONVERT" = false ]; then
                TOTAL=$(ls "$SCRATCH_HMI/$DIR"/* 2>/dev/null | wc -l)
                if [ "$TOTAL" -ge 2003 ]; then
                    log "  SKIP: Already has $TOTAL files (conversion done)"
                else
                    log "  Running FITS conversion..."
                    cd "$PROJECT_HMI"
                    ./scratch_convert_fits.newrr.disc.sh "$DR" hmi 2>&1 | tee -a "$LOGFILE"
                fi
            fi
            continue
        fi
        log "  Directory exists with $EXISTING FITS files, continuing download..."
    else
        mkdir -p "$SCRATCH_HMI/$DIR"
        chmod 775 "$SCRATCH_HMI/$DIR"
        log "  Created: $SCRATCH_HMI/$DIR"
    fi

    # --- Step 2: Create symlink ---
    if [ -L "$PROJECT_HMI/$DIR" ]; then
        LINK_TARGET=$(readlink "$PROJECT_HMI/$DIR")
        if [ "$LINK_TARGET" = "$SCRATCH_HMI/$DIR" ]; then
            log "  Symlink exists and correct"
        else
            log "  WARNING: Symlink points to $LINK_TARGET (expected $SCRATCH_HMI/$DIR)"
            if [ "$FORCE" = true ]; then
                unlink "$PROJECT_HMI/$DIR"
                ln -s "$SCRATCH_HMI/$DIR" "$PROJECT_HMI/$DIR"
                log "  Replaced symlink"
            else
                log "  Use --force to replace. Skipping..."
                FAIL=$((FAIL + 1))
                continue
            fi
        fi
    elif [ -d "$PROJECT_HMI/$DIR" ]; then
        log "  WARNING: $PROJECT_HMI/$DIR is a real directory, not a symlink. Skipping."
        FAIL=$((FAIL + 1))
        continue
    else
        ln -s "$SCRATCH_HMI/$DIR" "$PROJECT_HMI/$DIR"
        chgrp -h erhodes_44 "$PROJECT_HMI/$DIR" 2>/dev/null || true
        chmod 775 "$PROJECT_HMI/$DIR" 2>/dev/null || true
        log "  Created symlink: $PROJECT_HMI/$DIR -> $SCRATCH_HMI/$DIR"
    fi

    # --- Step 3: Download from JSOC ---
    log "  Downloading from JSOC (this may take 10-30 minutes)..."
    cd "$SCRIPT_DIR"

    if python3 -c "
import drms, os, sys, glob

out_dir = '$PROJECT_HMI/$DIR'
c = drms.Client(email='$EMAIL')
wordString = 'hmi.V_sht_pow[${MDIDN}d][0-1000][NDT=5760]'
print('  Query:', wordString)

r = c.export(wordString, method='url', protocol='fits', filenamefmt='{t_start_index}.{lmin}.fits')
print('  Request ID:', r.id, '  Status:', r.status)

if r.status != 0:
    print('  Waiting for JSOC to prepare data...')
    r.wait(sleep=30, timeout=7200)
    print('  Final status:', r.status)

if r.status != 0:
    print('  ERROR: Export failed with status', r.status)
    sys.exit(1)

print('  Downloading...')
r.download(out_dir)

count = len(glob.glob(os.path.join(out_dir, '*.fits')))
print(f'  Downloaded {count} FITS files')
if count != 1001:
    print(f'  WARNING: Expected 1001, got {count}')
    sys.exit(1)
" 2>&1 | tee -a "$LOGFILE"; then
        log "  Download complete: 1001 FITS files"

        # Fix permissions
        chmod 775 "$PROJECT_HMI/$DIR"/* 2>/dev/null || true
        chgrp erhodes_44 "$PROJECT_HMI/$DIR"/* 2>/dev/null || true

        # --- Step 4: Convert FITS ---
        if [ "$SKIP_CONVERT" = false ]; then
            log "  Submitting FITS conversion job..."
            cd "$PROJECT_HMI"
            ./scratch_convert_fits.newrr.disc.sh "$DR" hmi 2>&1 | tee -a "$LOGFILE"
        fi

        SUCCESS=$((SUCCESS + 1))
    else
        log "  FAILED: Download error for $DR"
        FAIL=$((FAIL + 1))
    fi

    log ""
done

#-----------------------------
# SUMMARY
#-----------------------------
log "============================================"
log "Pipeline complete for Run $RUN"
log "  Success: $SUCCESS"
log "  Skipped: $SKIP (already complete)"
log "  Failed:  $FAIL"
log "  Log: $LOGFILE"
log "============================================"

if [ $FAIL -gt 0 ]; then
    log ""
    log "To retry failed sets, check the log and use --start/--end options."
    exit 1
fi
