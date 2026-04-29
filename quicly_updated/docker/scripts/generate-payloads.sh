#!/bin/sh
# Generates payload files used by both the h2o server and load-testers.
# Run once on the host before `docker compose build`:
#
#   chmod +x scripts/generate-payloads.sh
#   ./scripts/generate-payloads.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOADS_DIR="${1:-${SCRIPT_DIR}/../payloads}"

mkdir -p "$PAYLOADS_DIR"
cd "$PAYLOADS_DIR"

echo "Generating payload files in $(pwd) ..."

dd if=/dev/zero bs=1K   count=100   of=100kb.bin       2>/dev/null
dd if=/dev/zero bs=1M   count=1     of=1mb.bin         2>/dev/null
dd if=/dev/zero bs=1M   count=5     of=5mb.bin         2>/dev/null
dd if=/dev/zero bs=1K   count=470   of=small_page.bin  2>/dev/null
dd if=/dev/zero bs=1K   count=1536  of=medium_page.bin 2>/dev/null
dd if=/dev/zero bs=1K   count=2867  of=large_page.bin  2>/dev/null

echo ""
ls -lh .
echo ""
echo "Done. Run 'docker compose build' next."
