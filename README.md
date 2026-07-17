# pipeline-v2 — HMI 3-Day Power Spectra Pipeline Automation

Wrapper scripts for the USC Solar Physics Group's HMI helioseismology data processing pipeline on the Discovery HPC cluster.

## Overview

This project automates the 6-part legacy pipeline for processing SDO/HMI 3-day power spectra. The original pipeline consists of dozens of Fortran programs, shell scripts, and SLURM jobs that must be run in sequence. These wrappers orchestrate each part with:

- **Dry-run mode** — preview all commands without executing
- **Validate mode** — check existing outputs without re-running
- **Checkpoint/resume** — recover from failures mid-run
- **Logging** — timestamped logs for every operation

All original scripts are called untouched. The wrappers only orchestrate.

## Directory Structure

```
pipeline-v2/
├── lib/
│   └── common.sh          # Shared function library
├── config/
│   ├── run_conf.template   # Config template
│   ├── run79.conf          # Run 79 configuration
│   └── run80.conf          # Run 80 configuration
├── run_3day_mavg.sh        # Part 2: M-Averaging & Renormalization
├── run_3day_convsub.sh     # Part 4: Conversion & Subtraction
├── run_3day_regtrans.sh    # Part 6: Regression & Transposition
├── fix_legacy_slurm.sh     # Post-prep fix for legacy SLURM files
├── pwinauto.py             # Python replacement for IDL pwin script
├── run_lookup.sh           # Run number ↔ MDIDN ↔ date range lookup
├── logs/                   # Runtime logs (gitignored)
└── checkpoints/            # Resume checkpoints (gitignored)
```

## Quick Start

```bash
# 1. Create config for a new run
cp config/run_conf.template config/run81.conf
# Edit run81.conf with MDIDN, date ranges

# 2. Run Part 2 (m-averaging)
./run_3day_mavg.sh --run 81 --dry-run          # Preview
./run_3day_mavg.sh --run 81 --test-container    # Verify container
./run_3day_mavg.sh --run 81                     # Execute
./run_3day_mavg.sh --run 81 --validate          # Check results

# 3. Fix legacy SLURM files after prep steps
./fix_legacy_slurm.sh --run 81 --part all

# 4. Generate pwin files (replaces IDL)
export OPENBLAS_NUM_THREADS=1
python3 pwinauto.py gaps1.fits gaps2.fits MDIDN 0 72 3 45.0
```

## Environment

- **HPC**: USC Discovery cluster, SLURM scheduler
- **Container**: Singularity/Apptainer with CentOS 7 image
- **Paths**: `/project2/erhodes_44/` (shared project), `/home1/dongpoba/pipeline-v2/` (this repo)
- **MDIDN formula**: `6256 + RUN_NUMBER × 72`

## Known Issues

- Legacy prep scripts generate SLURM files without bind mounts — run `fix_legacy_slurm.sh` after each prep step
- `slurm_wait` has a race condition on fast-completing jobs — includes initial 5s delay and sacct retry logic
- Testenv isolation does not work for rcf-57 writes due to Singularity bind mount limitations
- Some Fortran binaries (e.g., `bin2widthratiosdp`) need recompilation after CARC environment updates:
  `module load legacy/CentOS7 intel/19.0.4 && ifort -o exehpcc/bin2widthratiosdp src/bin2widthratiosdp.f`

## Author

Dongpo Bai (Eri) — USC Solar Physics Group, Prof. Edward Rhodes
