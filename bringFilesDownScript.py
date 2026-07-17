import drms
import os
import sys
import glob
import time

if len(sys.argv) < 3:
    print("Usage: python3 bringFilesDownScript.py MDIDN YYMMDDtoMMDD")
    print("  EX: python3 bringFilesDownScript.py 11656 241130to1202")
    sys.exit(1)

out_dir = '/project2/erhodes_44/rcf-93/data/spc/hmi/' + sys.argv[2].strip() + 'dpirlrr'
c = drms.Client(email='dongpoba@usc.edu')
wordString = 'hmi.V_sht_pow[' + sys.argv[1].strip() + 'd][0-1000][NDT=5760]'
print(wordString)

if not os.path.exists(out_dir):
    os.mkdir(out_dir)

print("Submitting export request...")
r = c.export(wordString, method='url', protocol='fits', filenamefmt='{t_start_index}.{lmin}.fits')
print("Export request ID:", r.id)
print("Initial status:", r.status)

# Wait for export to complete
print("Waiting for JSOC to prepare data...")
r.wait(sleep=30, timeout=7200)  # check every 30s, timeout after 2 hours
print("Final status:", r.status)

if r.status != 0:
    print("ERROR: Export failed with status", r.status)
    sys.exit(1)

print("Downloading to:", out_dir)
r.download(out_dir)

for f in glob.glob(os.path.join(out_dir, "*.fits")):
    os.chmod(f, 0o775)

print("Downloaded", len(glob.glob(os.path.join(out_dir, "*.fits"))), "fits files")
