#!/bin/bash
# ==============================================================================
# setup_testenv.sh — Create isolated test environment for pipeline-v2
#
# Creates a directory structure that mirrors /project2/erhodes_44/ using:
#   - Symlinks for read-only content (scripts, executables, shared data)
#   - Real directories + copied input files for writable content
#
# When the wrapper runs with PROJECT_BASE=testenv, the container sees
# /home/rcf-04/... pointing to testenv/ instead of project2/. All writes
# go to testenv; production is untouched.
#
# Usage:
#   ./setup_testenv.sh --run 80 [--dr-count 3] [--dry-run]
#   ./setup_testenv.sh --run 80 --teardown
#
# After setup:
#   ./run_3day_mavg.sh  --run 80 --config config/run80_test.conf --dry-run
#   ./run_3day_convsub.sh --run 80 --config config/run80_test.conf
#   ./run_3day_regtrans.sh --run 80 --config config/run80_test.conf
#   ./diff_testenv.sh --run 80   (compare test vs production outputs)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
DR_COUNT=3          # Number of date ranges to copy (default: first 3 for speed)
TEARDOWN=false
PROD_BASE=/project2/erhodes_44
TESTENV_BASE="${PIPELINE_DIR}/testenv"

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)       RUN_NUMBER="$2"; shift 2 ;;
        --dr-count)  DR_COUNT="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --teardown)  TEARDOWN=true; shift ;;
        --verbose)   VERBOSE=true; shift ;;
        --config)    CONFIG_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --run RR [--dr-count N] [--dry-run] [--teardown]"
            echo ""
            echo "  --run RR        Run number (required)"
            echo "  --dr-count N    Number of date ranges to test (default: 3, use 24 for full)"
            echo "  --dry-run       Show what would be done"
            echo "  --teardown      Remove testenv for this run"
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "${RUN_NUMBER:-}" ]]; then
    echo "ERROR: --run is required"
    exit 1
fi

# Load config
CONFIG_FILE="${CONFIG_FILE:-${PIPELINE_DIR}/config/run${RUN_NUMBER}.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi

RUN_NUMBER_PAD=$(printf "%02d" "$RUN_NUMBER")
MDIDN="${MDIDN:-$(echo "6256 + ($RUN_NUMBER * 72)" | bc)}"

# ── Teardown ─────────────────────────────────────────────────────────────────
if [[ "$TEARDOWN" == "true" ]]; then
    echo "Removing testenv: ${TESTENV_BASE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY] Would remove: ${TESTENV_BASE}"
    else
        rm -rf "$TESTENV_BASE"
        echo "Done."
    fi
    exit 0
fi

# ── Variable directory names ─────────────────────────────────────────────────
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
F96RR="final96b2b4rev6wtdhpccrr"

# ── Date ranges to use ───────────────────────────────────────────────────────
if [[ ${#DATE_RANGES[@]} -eq 0 ]]; then
    echo "ERROR: DATE_RANGES must be set in config"
    exit 1
fi
# Take only the first DR_COUNT date ranges
TEST_DRS=("${DATE_RANGES[@]:0:$DR_COUNT}")
echo "Will set up testenv for Run ${RUN_NUMBER} with ${#TEST_DRS[@]} date ranges:"
for dr in "${TEST_DRS[@]}"; do echo "  $dr"; done
echo ""

PROD_THEOR="${PROD_BASE}/rcf-04/astro10/wmltp/theor1.0"
TEST_THEOR="${TESTENV_BASE}/rcf-04/astro10/wmltp/theor1.0"

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Setting up testenv at ${TESTENV_BASE} ==="
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN MODE]"
    echo ""
fi

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY] $*"
    else
        "$@"
    fi
}

# Helper: symlink all items in a production directory into a testenv directory.
# Skips items that already exist in the target. Optionally excludes patterns.
# Usage: symlink_contents PROD_DIR TEST_DIR [EXCLUDE_PATTERN...]
symlink_contents() {
    local prod_dir="$1"
    local test_dir="$2"
    shift 2
    local excludes=("$@")

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY] Would symlink contents of ${prod_dir}/ → ${test_dir}/"
        return
    fi

    local count=0
    for item in "${prod_dir}"/*; do
        [[ ! -e "$item" && ! -L "$item" ]] && continue
        local base
        base=$(basename "$item")

        # Check excludes
        local skip=false
        for pat in "${excludes[@]}"; do
            if [[ "$base" == $pat ]]; then
                skip=true
                break
            fi
        done
        [[ "$skip" == "true" ]] && continue

        local target="${test_dir}/${base}"
        if [[ ! -e "$target" && ! -L "$target" ]]; then
            ln -s "$item" "$target"
            count=$((count + 1))
        fi
    done
    echo "  Symlinked ${count} items in $(basename "$prod_dir")/"
}

# ==============================================================================
# 1. rcf-93: full symlink (read-only — raw spectra for Part 1/2 input)
# ==============================================================================
echo "--- Step 1: rcf-93 (full symlink, read-only) ---"

run mkdir -p "${TESTENV_BASE}"

if [[ -L "${TESTENV_BASE}/rcf-93" ]]; then
    echo "  rcf-93: symlink already exists"
elif [[ -d "${TESTENV_BASE}/rcf-93" ]]; then
    echo "  rcf-93: directory already exists (manual setup?)"
else
    run ln -s "${PROD_BASE}/rcf-93" "${TESTENV_BASE}/rcf-93"
    echo "  rcf-93 → ${PROD_BASE}/rcf-93"
fi

# ==============================================================================
# 2. rcf-57: MIXED MODE (read-only symlinks + writable space for new output)
#
#    Part 2 creates new directories under rcf-57/astro0/data/:
#      - avgspc2880.wtnonavgcorrall.{DR}dpirlnewrr.hpcc/  (24 dirs)
#      - runRR.dateranges.lst, MDIDNxSETL.dateranges.lst
#      - Log dirs under spc28802lgc.{MDIDN}.logs/
#    Everything else (existing scripts, older runs) is symlinked read-only.
# ==============================================================================
echo ""
echo "--- Step 2: rcf-57 (mixed mode for Part 2) ---"

PROD_RCF57_DATA="${PROD_BASE}/rcf-57/astro0/data"
TEST_RCF57_DATA="${TESTENV_BASE}/rcf-57/astro0/data"

if [[ -L "${TESTENV_BASE}/rcf-57" ]]; then
    echo "  WARNING: rcf-57 is currently a plain symlink — removing to set up mixed mode"
    run rm "${TESTENV_BASE}/rcf-57"
fi

run mkdir -p "$TEST_RCF57_DATA"

# Symlink all existing content (scripts, old runs, etc.)
# New items created by the pipeline (for Run 80) will be real directories.
symlink_contents "$PROD_RCF57_DATA" "$TEST_RCF57_DATA"

# Also need rcf-57/astro0/ level items (if any non-data dirs exist)
PROD_RCF57_ASTRO="${PROD_BASE}/rcf-57/astro0"
TEST_RCF57_ASTRO="${TESTENV_BASE}/rcf-57/astro0"
for item in "${PROD_RCF57_ASTRO}"/*; do
    [[ ! -e "$item" ]] && continue
    base=$(basename "$item")
    [[ "$base" == "data" ]] && continue  # Already handled above
    target="${TEST_RCF57_ASTRO}/${base}"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        run ln -s "$item" "$target"
    fi
done

# Log directories on scratch (these are outside testenv, but Part 2 needs them)
SCRATCH_LOG_DIR="/scratch1/dongpoba/shared/logs/spc28802lgc.${MDIDN}.logs"
if [[ ! -d "$SCRATCH_LOG_DIR" ]]; then
    echo "  Creating scratch log directory: ${SCRATCH_LOG_DIR}"
    run mkdir -p "$SCRATCH_LOG_DIR"
fi

# ==============================================================================
# 3. rcf-04: selective structure
# ==============================================================================
echo ""
echo "--- Step 3: Create rcf-04 structure ---"

# 3a. Create theor1.0 top level and symlink everything from production
run mkdir -p "$TEST_THEOR"

echo "  Symlinking top-level items from production theor1.0/..."
if [[ "$DRY_RUN" != "true" ]]; then
    symlink_contents "$PROD_THEOR" "$TEST_THEOR" \
        "weightedhmi*" "*_hmi${MDIDN}" "hmi3dayall13zerocrossings"
else
    echo "  [DRY] Would symlink all items from ${PROD_THEOR}/"
fi

# 3b. Symlink other rcf-04 paths needed by scripts
echo "  Symlinking other rcf-04 paths..."
for subpath in \
    "rcf-04/astro10/data" \
    "rcf-04/astro10/windowtest" \
    "rcf-04/astro10/singularity" \
    "rcf-04/jreiter"; do
    prod_path="${PROD_BASE}/${subpath}"
    test_path="${TESTENV_BASE}/${subpath}"
    if [[ -d "$prod_path" && ! -e "$test_path" ]]; then
        run mkdir -p "$(dirname "$test_path")"
        run ln -s "$prod_path" "$test_path"
        echo "    ${subpath} → ${prod_path}"
    fi
done

# ==============================================================================
# 4. weightedhmi* D/ directories: copy .gz input files for Part 4
# ==============================================================================
echo ""
echo "--- Step 4: Copy fitting output (.gz files) for Part 4 input ---"

for DR in "${TEST_DRS[@]}"; do
    lgc="lgcfnonncorall96b2b4rev6asm"
    prod_d="${PROD_THEOR}/weightedhmi${DR}dpirlnewrr/fdxref61/${lgc}/D"
    test_d="${TEST_THEOR}/weightedhmi${DR}dpirlnewrr/fdxref61/${lgc}/D"

    if [[ ! -d "$prod_d" ]]; then
        echo "  INFO: Production D/ not found for ${DR} (expected for new runs)"
        continue
    fi

    run mkdir -p "$test_d"

    # Copy .gz files (Part 4 input — gunzip will extract them)
    gz_count=0
    if [[ "$DRY_RUN" != "true" ]]; then
        for gz in "${prod_d}"/*.gz; do
            [[ -f "$gz" ]] && cp "$gz" "$test_d/" && gz_count=$((gz_count + 1))
        done
        echo "  ${DR}: copied ${gz_count} .gz files"
    else
        gz_count=$(ls "${prod_d}"/*.gz 2>/dev/null | wc -l)
        echo "  [DRY] ${DR}: would copy ${gz_count} .gz files"
    fi

    # Symlink other files in the parent directories that scripts may need
    lgc_prod="${PROD_THEOR}/weightedhmi${DR}dpirlnewrr/fdxref61/${lgc}"
    lgc_test="${TEST_THEOR}/weightedhmi${DR}dpirlnewrr/fdxref61/${lgc}"
    if [[ "$DRY_RUN" != "true" ]]; then
        for item in "${lgc_prod}"/*; do
            base=$(basename "$item")
            [[ "$base" == "D" ]] && continue
            [[ ! -e "${lgc_test}/${base}" ]] && ln -s "$item" "${lgc_test}/${base}"
        done
    fi
done

# ==============================================================================
# 5. 13 variable directories: create empty writable structure
# ==============================================================================
echo ""
echo "--- Step 5: Create 13 empty variable directories for Part 4 output ---"

for vardir in "${VAR_DIRS[@]}"; do
    test_var="${TEST_THEOR}/${vardir}${MDIDN}"
    run mkdir -p "${test_var}/${F96}"
    run mkdir -p "${test_var}/${F96RR}"
done
echo "  Created ${#VAR_DIRS[@]} variable directory sets"

# ==============================================================================
# 6. hmi3dayall13zerocrossings: create empty directory for Part 6 output
# ==============================================================================
echo ""
echo "--- Step 6: Create zero crossings output directory ---"

run mkdir -p "${TEST_THEOR}/hmi3dayall13zerocrossings"
echo "  Created hmi3dayall13zerocrossings/"

# ==============================================================================
# 7. Generate test config file
# ==============================================================================
echo ""
echo "--- Step 7: Generate test config ---"

TEST_CONFIG="${PIPELINE_DIR}/config/run${RUN_NUMBER}_test.conf"

if [[ "$DRY_RUN" != "true" ]]; then
    cat > "$TEST_CONFIG" << CONFEOF
# ==============================================================================
# Run ${RUN_NUMBER} TEST Configuration — pipeline-v2
# Auto-generated by setup_testenv.sh on $(date)
#
# PROJECT_BASE points to testenv/ — all writes go here, not to production.
# ==============================================================================

RUN_NUMBER=${RUN_NUMBER}
MDIDN=${MDIDN}
SETL=${#TEST_DRS[@]}
INSTRUMENT=${INSTRUMENT}

# TEST MODE: point to testenv instead of production
PROJECT_BASE=${TESTENV_BASE}
SCRATCH_BASE=/scratch1/dongpoba
CONTAINER_IMAGE=${CONTAINER_IMAGE}

# Date ranges (${#TEST_DRS[@]} of ${#DATE_RANGES[@]} for testing)
DATE_RANGES=(
$(for dr in "${TEST_DRS[@]}"; do echo "    \"${dr}\""; done)
)
CONFEOF
    echo "  Generated: ${TEST_CONFIG}"
    echo "  PROJECT_BASE=${TESTENV_BASE}"
else
    echo "  [DRY] Would generate: ${TEST_CONFIG}"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Testenv setup complete!"
echo "══════════════════════════════════════════════════════════════════"
echo ""
echo "Directory: ${TESTENV_BASE}"
if [[ "$DRY_RUN" != "true" ]]; then
    echo "  rcf-57/astro0/data/ — $(find "${TEST_RCF57_DATA}" -maxdepth 1 -type l | wc -l) symlinks (mixed mode)"
    echo "  rcf-93/              — full symlink"
    echo "  rcf-04/              — selective structure"
    du -sh "$TESTENV_BASE" 2>/dev/null || true
fi
echo ""
echo "To test Part 2 (m-averaging + renormalization):"
echo "  ./run_3day_mavg.sh --run ${RUN_NUMBER} --config config/run${RUN_NUMBER}_test.conf --dry-run"
echo "  ./run_3day_mavg.sh --run ${RUN_NUMBER} --config config/run${RUN_NUMBER}_test.conf"
echo ""
echo "To test Part 4 (conversion + subtraction):"
echo "  ./run_3day_convsub.sh --run ${RUN_NUMBER} --config config/run${RUN_NUMBER}_test.conf --dry-run"
echo ""
echo "To test Part 6 (regression + transposition):"
echo "  ./run_3day_regtrans.sh --run ${RUN_NUMBER} --config config/run${RUN_NUMBER}_test.conf --dry-run"
echo ""
echo "To tear down:"
echo "  ./setup_testenv.sh --run ${RUN_NUMBER} --teardown"
echo ""
echo "NOTE: After running Part 2 prep steps (genDRlist + prepmavgrenorm),"
echo "check the generated SLURM files for hardcoded bind paths:"
echo "  grep '/project2/erhodes_44' testenv/rcf-57/astro0/data/avgspc2880.*/sbatch*.slurm"
echo "If found, patch them:"
echo "  sed -i 's|/project2/erhodes_44|${TESTENV_BASE}|g' testenv/rcf-57/astro0/data/avgspc2880.*/sbatch*.slurm"