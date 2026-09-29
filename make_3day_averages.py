#!/usr/bin/env python3
"""Make the six 3day*averages files for one HMI run from its daily activity file.

Reproduces the files Dr. Rhodes built by hand, e.g.
  3dayINTv2.0averages.112525to020426.032026.dat
One line per 3-day set (24 per run):
  middle-day number (F11.1), 3 (I6), mean, sample std (n-1), std/sqrt(3) (3E17.8)

Usage:
  python3 make_3day_averages.py --run 80 --outdir ~/p5test --compare $C
  python3 make_3day_averages.py --run 81 --outdir ~/p5run81
Nothing is ever written to the comparison directory by this script.
"""
import argparse
import datetime
import glob
import math
import os
import sys

COMPARISON = "/project2/erhodes_44/rcf-04/astro10/data/mdi/lnu/comparison"

# (name used in the file name, 1-based column in dailyactivityvalueshmirunNN.dat)
INDICES = [
    ("INTv2.0", 8),
    ("American", 9),
    ("10.7cm", 10),
    ("SEMF0", 13),
    ("SEMF1", 14),
    ("MgIIv2.0", 19),
]
MISSING = -1.0
SETLEN = 3


def fortran_e(x, w=17, d=8):
    """Fortran Ew.d with a 0.ddd mantissa, e.g. 0.90333333E+02."""
    if x == 0.0:
        mant, exp = 0.0, 0
    else:
        exp = math.floor(math.log10(abs(x))) + 1
        mant = x / 10.0 ** exp
        if abs(round(mant, d)) >= 1.0:
            exp += 1
            mant = x / 10.0 ** exp
        elif abs(round(mant, d)) < 0.1:
            exp -= 1
            mant = x / 10.0 ** exp
    s = f"{mant:.{d}f}E{exp:+03d}"
    return s.rjust(w)


def read_daily(path):
    rows = []
    with open(path) as f:
        for line in f:
            if line.strip():
                rows.append(line.split())
    return rows


def build(rows):
    if len(rows) % SETLEN:
        sys.exit(f"ERROR: {len(rows)} daily rows is not a multiple of {SETLEN}")
    out = {name: [] for name, _ in INDICES}
    missing = []
    for s in range(0, len(rows), SETLEN):
        chunk = rows[s:s + SETLEN]
        label = float(chunk[1][1])
        for name, col in INDICES:
            vals = [float(r[col - 1]) for r in chunk]
            if any(v == MISSING for v in vals):
                missing.append((name, chunk[1][1], vals))
                continue
            mean = sum(vals) / SETLEN
            std = math.sqrt(sum((v - mean) ** 2 for v in vals) / (SETLEN - 1))
            sem = std / math.sqrt(SETLEN)
            out[name].append(f"{label:11.1f}{SETLEN:6d}" + fortran_e(mean)
                             + fortran_e(std) + fortran_e(sem))
    return out, missing


def date_range(rows):
    a, b = rows[0], rows[-1]
    return (f"{int(a[3]):02d}{int(a[4]):02d}{a[2][2:]}to"
            f"{int(b[3]):02d}{int(b[4]):02d}{b[2][2:]}")


def compare(out, dr, refdir):
    total_bad = 0
    for name, _ in INDICES:
        cands = sorted(glob.glob(os.path.join(refdir, f"3day{name}averages.{dr}.*.dat")),
                       key=os.path.getmtime)
        cands = [c for c in cands if not c.endswith("~")]
        if not cands:
            print(f"[{name}] no reference file for {dr}")
            total_bad += 1
            continue
        ref = cands[-1]
        with open(ref) as f:
            rlines = [l.rstrip("\n") for l in f if l.strip()]
        mine = out[name]
        bad = [(i, a, b) for i, (a, b) in enumerate(zip(mine, rlines)) if a != b]
        if len(mine) != len(rlines):
            print(f"[{name}] line count differs: mine {len(mine)} vs ref {len(rlines)}")
            total_bad += 1
        print(f"[{name}] {len(mine) - len(bad)}/{len(rlines)} lines byte-identical  (ref {os.path.basename(ref)})")
        for i, a, b in bad:
            print(f"    row {i + 1:2d} mine: {a}")
            print(f"           ref : {b}")
        total_bad += len(bad)
    return total_bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=int, required=True)
    ap.add_argument("--daily", help="daily file (default: comparison/dailyactivityvalueshmirunNN.dat)")
    ap.add_argument("--outdir", required=True, help="where to write; must not be the comparison dir")
    ap.add_argument("--stamp", help="MMDDYY date stamp in the file names (default: today)")
    ap.add_argument("--compare", metavar="DIR", help="compare against existing files in DIR, write nothing")
    args = ap.parse_args()

    daily = args.daily or os.path.join(COMPARISON, f"dailyactivityvalueshmirun{args.run}.dat")
    rows = read_daily(daily)
    if len(rows) != 72:
        print(f"WARNING: {len(rows)} daily rows (expected 72)")
    dr = date_range(rows)
    out, missing = build(rows)
    print(f"Run {args.run}: {len(rows)} daily rows, date range {dr}, {len(rows) // SETLEN} sets")

    if missing:
        print("\nSTOPPED: sets containing missing values (-1), not averaged:")
        for name, day, vals in missing:
            print(f"  {name:9s} set day {day}: {vals}")
        sys.exit(2)

    if args.compare:
        bad = compare(out, dr, args.compare)
        print("\nRESULT:", "ALL BYTE-IDENTICAL" if bad == 0 else f"{bad} differing lines/files")
        sys.exit(0 if bad == 0 else 1)

    outdir = os.path.realpath(os.path.expanduser(args.outdir))
    if outdir == os.path.realpath(COMPARISON):
        sys.exit("ERROR: refusing to write into the comparison directory")
    os.makedirs(outdir, exist_ok=True)
    stamp = args.stamp or datetime.date.today().strftime("%m%d%y")
    for name, _ in INDICES:
        p = os.path.join(outdir, f"3day{name}averages.{dr}.{stamp}.dat")
        with open(p, "w") as f:
            f.write("\n".join(out[name]) + "\n")
        print(f"wrote {p} ({len(out[name])} lines)")


if __name__ == "__main__":
    main()
