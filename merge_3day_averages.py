#!/usr/bin/env python3
"""
merge_3day_averages.py — Merge 6 individual 3-day activity index files
into the combined 17-column format used by the pipeline.

Usage:
    python3 merge_3day_averages.py --run 80 --start-seq 1897
    python3 merge_3day_averages.py --runs 76,77,78,79,80 --start-seq 1801
    python3 merge_3day_averages.py --runs 76,77,78,79,80 --start-seq 1801 --cumulative

Output: 3dayaveactivityvalueshmirunXX.MMDDYY.dat (per-run)
        3dayaveactivityvalueshmiruns01toXX.MMDDYY.dat (cumulative, if --cumulative)
"""
import sys
import os
import glob
import re
import argparse
from datetime import datetime

BASEDIR = "/project2/erhodes_44/rcf-04/astro10/data/mdi/lnu/comparison"

# Optional explicit override of (date_range, date_stamp) per run. Runs NOT listed
# here are auto-discovered from the daily-indices file + the on-disk 3day files
# (see discover_run_files). Kept for reproducibility of historical runs; new runs
# need no entry here.
RUN_FILES = {
    76: ("021025to042225", "031826"),
    77: ("042325to070325", "031926"),
    78: ("070425to091325", "031926"),
    79: ("091425to112425", "031926"),
    80: ("112525to020426", "032026"),
}

# The 6 index file prefixes and their column mapping
# Format: (file_prefix, missing_value_for_unused_cols)
INDEX_FILES = [
    "3dayINTv2.0averages",      # → col 6: RI2
    "3dayAmericanaverages",      # → col 7: RA
    "3day10.7cmaverages",        # → col 8: radio flux
    "3daySEMF0averages",         # → col 11: SEM0
    "3daySEMF1averages",         # → col 12: SEM1
    "3dayMgIIv2.0averages",      # → col 17: MgII
]


def date_range_from_daily(run_num, basedir=BASEDIR):
    """Derive the 72-day date_range 'MMDDYYtoMMDDYY' from the daily-indices file
    produced by solar-activity-pipeline (dailyactivityvalueshmirunNN.dat), using
    its first and last data rows (columns 3-5 = year, month, day)."""
    f = os.path.join(basedir, f"dailyactivityvalueshmirun{run_num}.dat")
    if not os.path.exists(f):
        raise FileNotFoundError(f"daily-indices file not found: {f}")
    with open(f) as fh:
        lines = [ln for ln in fh if ln.strip()]
    if not lines:
        raise ValueError(f"daily-indices file is empty: {f}")

    def mmddyy(line):
        p = line.split()
        yyyy, mm, dd = p[2], p[3], p[4]
        return f"{int(mm):02d}{int(dd):02d}{yyyy[2:]}"

    return f"{mmddyy(lines[0])}to{mmddyy(lines[-1])}"


def discover_run_files(run_num, basedir=BASEDIR):
    """Return (date_range, date_stamp) for a run by discovery, no hardcoding.
    date_range comes from the daily-indices file; date_stamp is read from the
    on-disk 3day*averages filenames for that date_range (newest if several).
    Verifies all 6 index files are present for the chosen (date_range, date_stamp)."""
    date_range = date_range_from_daily(run_num, basedir)

    pattern = os.path.join(basedir, f"{INDEX_FILES[0]}.{date_range}.*.dat")
    hits = sorted(glob.glob(pattern))
    if not hits:
        raise FileNotFoundError(
            f"no {INDEX_FILES[0]} file for date_range {date_range} in {basedir}; "
            f"the 6 manual 3day*averages inputs may not be generated yet")

    stamps = set()
    for h in hits:
        m = re.search(rf"{re.escape(date_range)}\.(\d+)\.dat$", os.path.basename(h))
        if m:
            stamps.add(m.group(1))
    if not stamps:
        raise ValueError(f"could not parse date_stamp from: {hits}")
    date_stamp = sorted(stamps)[-1]  # newest stamp if multiple

    missing = [p for p in INDEX_FILES
               if not os.path.exists(os.path.join(basedir, f"{p}.{date_range}.{date_stamp}.dat"))]
    if missing:
        raise FileNotFoundError(
            f"date_range {date_range} stamp {date_stamp}: missing {len(missing)} "
            f"of 6 index files: {missing}")

    return date_range, date_stamp


def read_index_file(filepath):
    """Read a 3-day average file. Returns list of (mdidn, mean) tuples."""
    data = []
    with open(filepath) as f:
        for line in f:
            parts = line.split()
            mdidn = int(float(parts[0]))
            mean = float(parts[2])
            data.append((mdidn, mean))
    return data


def fortran_e12_5(val):
    """Format float as Fortran e12.5: ' 0.XXXXXE+XX'"""
    if val == 0:
        return "  0.00000E+00"
    import math
    sign = "-" if val < 0 else " "
    aval = abs(val)
    exp = int(math.floor(math.log10(aval))) + 1
    mantissa = aval / (10 ** exp)
    return f"{sign}{mantissa:.5f}E{exp:+03d}"


def mdidn_to_yearfract(mdidn):
    """Convert MDIDN to fractional year. Matches Rhodes' convention."""
    return mdidn / 365.25 + 2000.0


def format_row(seq, mdidn, ndays, yearfract, ri2, ra, radioflux,
               sem0, sem1, mgii):
    """Format one row matching the 17-column format of existing files.

    Fortran format:
    I4,x,I5,1x,I1,1x,f8.3,1x,f9.4,1x,f9.4,1x,f8.4,1x,
    f8.4,1x,f9.6,1x,f9.6,1x,e12.5,1x,e12.5,1x,f10.5,1x,f10.5,
    1x,f7.4,1x,f7.4,1x,f8.6
    """
    return (
        f"{seq:4d} {mdidn:5d} {ndays:1d} "
        f"{yearfract:8.3f} "
        f"{'%9.4f' % -1.0} "          # RI (missing)
        f"{ri2:9.4f} "                  # RI2/INTv2.0
        f"{ra:8.4f} "                   # RA/American
        f"{radioflux:8.4f} "            # radio flux/10.7cm
        f"{-1.0:9.6f} "                 # MPSI (missing)
        f"{-1.0:9.6f} "                 # MWSI (missing)
        f"{fortran_e12_5(sem0)} "                # SEM0
        f"{fortran_e12_5(sem1)} "                # SEM1
        f"{'%10.5f' % -1.0} "          # TSI (missing)
        f"{'%10.5f' % -1.0} "          # TSIv17 (missing)
        f"{-1.0:7.4f} "                 # bcorrabs (missing)
        f"{-1.0:7.4f} "                 # bcorrabs2 (missing)
        f"{mgii:8.6f}"                   # MgII
    )


def merge_run(run_num, start_seq):
    """Merge 6 index files for one run into 17-column format."""
    if run_num in RUN_FILES:
        date_range, date_stamp = RUN_FILES[run_num]        # explicit override
    else:
        try:
            date_range, date_stamp = discover_run_files(run_num)   # auto-discover
            print(f"  Auto-discovered: date_range={date_range}, date_stamp={date_stamp}")
        except (FileNotFoundError, ValueError) as e:
            print(f"ERROR: {e}")
            return None

    # Read all 6 index files
    all_data = {}
    for prefix in INDEX_FILES:
        fname = f"{prefix}.{date_range}.{date_stamp}.dat"
        fpath = os.path.join(BASEDIR, fname)
        if not os.path.exists(fpath):
            print(f"ERROR: File not found: {fpath}")
            return None
        data = read_index_file(fpath)
        all_data[prefix] = data
        print(f"  Read {fname}: {len(data)} rows")

    # Verify all files have same number of rows and same MDIDNs
    nrows = len(all_data[INDEX_FILES[0]])
    for prefix in INDEX_FILES[1:]:
        if len(all_data[prefix]) != nrows:
            print(f"ERROR: Row count mismatch: {prefix} has {len(all_data[prefix])}, expected {nrows}")
            return None

    # Merge
    rows = []
    for i in range(nrows):
        mdidn = all_data[INDEX_FILES[0]][i][0]
        # Verify all files have same MDIDN for this row
        for prefix in INDEX_FILES[1:]:
            if all_data[prefix][i][0] != mdidn:
                print(f"ERROR: MDIDN mismatch at row {i}: {prefix} has {all_data[prefix][i][0]}, expected {mdidn}")
                return None

        yearfract = mdidn_to_yearfract(mdidn)
        seq = start_seq + i

        ri2 = all_data["3dayINTv2.0averages"][i][1]
        ra = all_data["3dayAmericanaverages"][i][1]
        radioflux = all_data["3day10.7cmaverages"][i][1]
        sem0 = all_data["3daySEMF0averages"][i][1]
        sem1 = all_data["3daySEMF1averages"][i][1]
        mgii = all_data["3dayMgIIv2.0averages"][i][1]

        row = format_row(seq, mdidn, 3, yearfract,
                         ri2, ra, radioflux, sem0, sem1, mgii)
        rows.append(row)

    return rows


def main():
    parser = argparse.ArgumentParser(description="Merge 3-day activity averages")
    parser.add_argument("--run", type=int, help="Single run number")
    parser.add_argument("--runs", type=str, help="Comma-separated run numbers (e.g., 76,77,78,79,80)")
    parser.add_argument("--start-seq", type=int, required=True, help="Starting sequence number")
    parser.add_argument("--cumulative", action="store_true", help="Also generate cumulative file appended to runs01to75")
    parser.add_argument("--outdir", type=str, default=BASEDIR, help="Output directory")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing")
    args = parser.parse_args()

    if args.run:
        runs = [args.run]
    elif args.runs:
        runs = [int(x) for x in args.runs.split(",")]
    else:
        print("ERROR: --run or --runs required")
        sys.exit(1)

    today = datetime.now().strftime("%m%d%y")
    seq = args.start_seq
    all_rows = []

    for run_num in runs:
        print(f"\n=== Run {run_num} (start_seq={seq}) ===")
        rows = merge_run(run_num, seq)
        if rows is None:
            print(f"FAILED for Run {run_num}")
            sys.exit(1)

        # Write per-run file
        outname = f"3dayaveactivityvalueshmirun{run_num}.{today}.dat"
        outpath = os.path.join(args.outdir, outname)
        if args.dry_run:
            print(f"  [DRY] Would write {outname} ({len(rows)} rows)")
            print(f"  First row: {rows[0]}")
            print(f"  Last row:  {rows[-1]}")
        else:
            with open(outpath, "w") as f:
                for row in rows:
                    f.write(row + "\n")
            print(f"  Wrote {outpath} ({len(rows)} rows)")

        all_rows.extend(rows)
        seq += len(rows)

    # Cumulative file
    if args.cumulative:
        last_run = runs[-1]
        cumname = f"3dayaveactivityvalueshmiruns01to{last_run}.{today}.dat"
        prev_file = os.path.join(BASEDIR, "3dayaveactivityvalueshmiruns01to75.031925.dat")

        if not os.path.exists(prev_file):
            print(f"ERROR: Previous cumulative file not found: {prev_file}")
            sys.exit(1)

        cumpath = os.path.join(args.outdir, cumname)
        if args.dry_run:
            print(f"\n  [DRY] Would write {cumname} (1800 + {len(all_rows)} = {1800 + len(all_rows)} rows)")
        else:
            with open(prev_file) as f:
                prev_data = f.read()
            with open(cumpath, "w") as f:
                f.write(prev_data)
                for row in all_rows:
                    f.write(row + "\n")
            total = 1800 + len(all_rows)
            print(f"\n  Wrote {cumpath} ({total} rows)")

    print("\nDone.")


if __name__ == "__main__":
    main()
