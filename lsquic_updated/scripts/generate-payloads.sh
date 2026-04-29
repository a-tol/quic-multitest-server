#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_DIR="$(cd "$(dirname "$0")/.." && pwd)/payloads"
mkdir -p "$PAYLOAD_DIR"

echo "Generating payload files in $PAYLOAD_DIR ..."

dd if=/dev/urandom of="$PAYLOAD_DIR/100kb.bin"      bs=1024  count=100   2>/dev/null
dd if=/dev/urandom of="$PAYLOAD_DIR/1mb.bin"         bs=1024  count=1024  2>/dev/null
dd if=/dev/urandom of="$PAYLOAD_DIR/5mb.bin"         bs=1024  count=5120  2>/dev/null
dd if=/dev/urandom of="$PAYLOAD_DIR/small_page.bin"  bs=1024  count=20    2>/dev/null
dd if=/dev/urandom of="$PAYLOAD_DIR/medium_page.bin" bs=1024  count=200   2>/dev/null
dd if=/dev/urandom of="$PAYLOAD_DIR/large_page.bin"  bs=1024  count=500   2>/dev/null

echo ""
ls -lh "$PAYLOAD_DIR"
echo ""
echo "Payloads generated successfully."
