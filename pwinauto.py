#!/usr/bin/env python
"""
pwinauto.py: Python replacement for pwinauto.pro (IDL)

Reads two FITS gap files from JSOC and computes window sum values
needed for psdrenormalization in the HMI pipeline.

Usage:
    python pwinauto.py GAPFILE GFGAPFILE STARTDAY OFFDAYS NDAYS STEPDAYS TSTEP

Example (Run 80):
    python pwinauto.py \
        /SUM93/D1971250833/S00000/gaps.fits \
        /SUM84/D1971259759/S00000/gaps.fits \
        12016 0 72 3 45.0

Output columns are %14.5f and %11.5e, which is NOT the IDL pwinauto.pro
layout (%16.5f and %13.5f). The downstream Fortran reads both, and Run 80
went through Part 6 on this format. No manual reformatting is needed.
"""
from __future__ import print_function
import sys
import numpy as np

def read_fits_data(filename):
    """Read FITS file data array. Tries astropy first, then pyfits."""
    try:
        from astropy.io import fits
        hdul = fits.open(filename)
        data = hdul[0].data.astype(np.float64)
        hdul.close()
        return data
    except ImportError:
        pass
    try:
        import pyfits
        hdul = pyfits.open(filename)
        data = hdul[0].data.astype(np.float64)
        hdul.close()
        return data
    except ImportError:
        pass
    raise ImportError("Neither astropy.io.fits nor pyfits available")


def main():
    if len(sys.argv) != 8:
        print("Usage: {} GAPFILE GFGAPFILE STARTDAY OFFDAYS NDAYS STEPDAYS TSTEP".format(sys.argv[0]))
        print("Example: {} /SUM93/.../gaps.fits /SUM84/.../gaps.fits 12016 0 72 3 45.0".format(sys.argv[0]))
        sys.exit(1)

    file1 = sys.argv[1]
    file2 = sys.argv[2]
    startday = int(sys.argv[3])
    offdays = int(sys.argv[4])
    ndays = int(sys.argv[5])
    stepdays = int(sys.argv[6])
    tstep = float(sys.argv[7])

    ppd = int(86400 / tstep)

    print("Reading {}".format(file1))
    g = read_fits_data(file1)
    print("  shape: {}, dtype: {}".format(g.shape, g.dtype))

    print("Reading {}".format(file2))
    gf = read_fits_data(file2)
    print("  shape: {}, dtype: {}".format(gf.shape, gf.dtype))

    i0 = offdays * ppd
    ndt = ndays * ppd

    g0_full = g[i0:i0+ndt]
    gx_full = gf[i0:i0+ndt]
    gfdc_full = np.mean(gx_full)

    with open('pwin.out', 'w') as f2:
        f2.write("{:5d} {:2d} {:.5f} {:.5f} {:.5f}\n".format(
            startday + offdays, ndays,
            np.mean(g0_full), gfdc_full, 1.0 / gfdc_full))

        # Full-range power spectrum. Columns: %14.5f  %11.5e (see the header)
        px_full = np.abs(np.fft.fft(gx_full)) ** 2
        df = 1e6 / tstep / ndt
        nx = int(200 / df)
        fname_full = "pwin.{}.{}".format(ndays, startday + offdays)
        with open(fname_full, 'w') as f1:
            for j in range(-nx, nx + 1):
                idx = abs(j)
                f1.write("{:14.5f}  {:11.5e}\n".format(j * df, px_full[idx] / px_full[0]))
        print("Wrote {}".format(fname_full))

        # Per-period (3-day steps)
        nperiods = ndays // stepdays
        ndt_step = stepdays * ppd
        df_step = 1e6 / tstep / ndt_step
        nx_step = int(200 / df_step)

        for i3 in range(nperiods):
            i = i0 + ndt_step * i3
            g0 = g[i:i+ndt_step]
            gx = gf[i:i+ndt_step]
            gfdc = np.mean(gx)

            f2.write("{:5d} {:2d} {:.5f} {:.5f} {:.5f}\n".format(
                startday + offdays + stepdays * i3, stepdays,
                np.mean(g0), gfdc, 1.0 / gfdc))

            px = np.abs(np.fft.fft(gx)) ** 2
            daynum = startday + offdays + stepdays * i3
            fname_step = "pwin.{:02d}.{}".format(stepdays, daynum)
            with open(fname_step, 'w') as f1:
                for j in range(-nx_step, nx_step + 1):
                    idx = abs(j)
                    f1.write("{:14.5f}  {:11.5e}\n".format(j * df_step, px[idx] / px[0]))

        print("Wrote {} period files + pwin.out".format(nperiods))

    print("\nFiles generated:")
    print("  pwin.out ({} lines)".format(1 + ndays // stepdays))
    print("  pwin.{}.{} (full-range spectrum)".format(ndays, startday + offdays))
    print("  pwin.XX.MDIDN ({} period spectra)".format(nperiods))


if __name__ == '__main__':
    main()
