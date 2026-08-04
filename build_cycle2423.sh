#!/bin/bash
#=============================================================================
# build_cycle2423.sh
# Compile cycle2423 zero-crossing regression programs with GSL replacements
# for IMSL DRLINE and DRCURV routines.
#
# Must be run INSIDE the Singularity container on Discovery.
#
# Usage: ./build_cycle2423.sh [program_name]
#   No args: build all 6 priority programs
#   With arg: build just one (e.g. ./build_cycle2423.sh corrmp)
#
# Prerequisites:
#   - GSL installed (available inside container at standard paths)
#   - gfortran and gcc available inside container
#   - fakeDRLINE.c and fakeDRCURV.c in same directory as this script
#=============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZPC_DIR="/home/rcf-04/astro10/wmltp/theor1.0/zeropointcomparisons"

# GSL paths inside the container
GSL_INC="/usr/include"
GSL_LIB="/usr/lib64"

# Compilers
FC=gfortran
CC="/usr/bin/gcc -I/usr/lib/gcc/x86_64-redhat-linux/4.8.5/include"

# The 6 priority programs (short names → source file mapping)
declare -A PROGRAMS=(
    [corrmp]="cycle2423corrmpzerocrossingregressionstatscomparisonsdp6"
    [corrpm]="cycle2423corrpmzerocrossingregressionstatscomparisonsdp6"
    [slopemp]="cycle2423slopempzerocrossingregressionstatscomparisonsdp6"
    [slopepm]="cycle2423slopepmzerocrossingregressionstatscomparisonsdp6"
    [avemp]="cycle2423avempzerocrossingregressionstatscomparisonsdp6"
    [avepm]="cycle2423avepmzerocrossingregressionstatscomparisonsdp6"
)

# Build fake IMSL object files
build_fakes() {
    echo "=== Compiling fakeDRLINE.o ==="
    ${CC} -c -O2 -I${GSL_INC} -o "${SCRIPT_DIR}/fakeDRLINE.o" "${SCRIPT_DIR}/fakeDRLINE.c"

    echo "=== Compiling fakeDRCURV.o ==="
    ${CC} -c -O2 -I${GSL_INC} -o "${SCRIPT_DIR}/fakeDRCURV.o" "${SCRIPT_DIR}/fakeDRCURV.c"
}

# Build one program
build_one() {
    local shortname="$1"
    local basename="${PROGRAMS[$shortname]}"
    local srcfile="${ZPC_DIR}/${basename}.f"
    local exefile="${ZPC_DIR}/${basename}"
    local objfile="${SCRIPT_DIR}/${basename}.o"

    if [ ! -f "$srcfile" ]; then
        echo "ERROR: Source not found: $srcfile"
        return 1
    fi

    # Backup original executable if it exists and hasn't been backed up
    if [ -f "$exefile" ] && [ ! -f "${exefile}.imsl.bak" ]; then
        echo "  Backing up original: ${exefile}.imsl.bak"
        cp "$exefile" "${exefile}.imsl.bak"
    fi

    echo "=== Compiling ${basename}.f ==="
    ${FC} -c -O2 -o "$objfile" "$srcfile"

    echo "=== Linking ${basename} ==="
    ${FC} -o "$exefile" "$objfile" \
        "${SCRIPT_DIR}/fakeDRLINE.o" \
        "${SCRIPT_DIR}/fakeDRCURV.o" \
        -L${GSL_LIB} -lgsl -lgslcblas -lm

    echo "  Built: $exefile"
    echo "  Size: $(ls -lh "$exefile" | awk '{print $5}')"

    # Clean up object file
    rm -f "$objfile"
}

# Main
echo "============================================"
echo "Building cycle2423 programs (IMSL-free)"
echo "============================================"

# Check we're in a container
if [ ! -d "/home/rcf-04" ]; then
    echo "ERROR: Must be run inside the Singularity container (sing)"
    exit 1
fi

# Check GSL
if [ ! -f "${GSL_LIB}/libgsl.so" ] && [ ! -f "${GSL_LIB}/libgsl.a" ]; then
    echo "ERROR: GSL not found at ${GSL_LIB}"
    exit 1
fi

# Check fake source files
if [ ! -f "${SCRIPT_DIR}/fakeDRLINE.c" ] || [ ! -f "${SCRIPT_DIR}/fakeDRCURV.c" ]; then
    echo "ERROR: fakeDRLINE.c and/or fakeDRCURV.c not found in ${SCRIPT_DIR}"
    exit 1
fi

# Build fake IMSL objects
build_fakes

if [ $# -eq 0 ]; then
    # Build all 6
    for prog in corrmp corrpm slopemp slopepm avemp avepm; do
        echo ""
        build_one "$prog"
    done
else
    # Build specified program(s)
    for prog in "$@"; do
        if [ -z "${PROGRAMS[$prog]+x}" ]; then
            echo "ERROR: Unknown program '$prog'"
            echo "Valid names: ${!PROGRAMS[*]}"
            exit 1
        fi
        echo ""
        build_one "$prog"
    done
fi

echo ""
echo "============================================"
echo "Build complete!"
echo "============================================"
