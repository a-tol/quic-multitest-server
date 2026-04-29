#!/bin/bash
# Generates non-compressible random payload files matching the paper's test sizes.
# Usage: ./scripts/generate-payloads.sh [output-dir]

set -e

OUTDIR="${1:-./payloads}"
mkdir -p "$OUTDIR"

echo "Generating payload files in $OUTDIR ..."

# Raw protocol benchmarks
dd if=/dev/urandom of="$OUTDIR/100kb.bin"      bs=1K   count=100   status=none
dd if=/dev/urandom of="$OUTDIR/1mb.bin"        bs=1M   count=1     status=none
dd if=/dev/urandom of="$OUTDIR/5mb.bin"        bs=1M   count=5     status=none

# Web-page tier benchmarks (paper categories: small ≤0.47 MB, medium ≤1.54 MB, large ≤2.83 MB)
dd if=/dev/urandom of="$OUTDIR/small_page.bin"  bs=1K  count=470   status=none
dd if=/dev/urandom of="$OUTDIR/medium_page.bin" bs=1K  count=1540  status=none
dd if=/dev/urandom of="$OUTDIR/large_page.bin"  bs=1K  count=2830  status=none

echo ""
echo "Done. Files created:"
ls -lh "$OUTDIR"
