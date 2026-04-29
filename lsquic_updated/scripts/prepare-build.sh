#!/usr/bin/env bash
# Run this once before the first `docker compose build`.
# It clones BoringSSL and initializes lsquic submodules so Docker builds
# need no network access at all.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Step 1: git submodules (ls-hpack, ls-qpack) ==="
cd "$REPO"
git submodule update --init src/lshpack src/liblsquic/ls-qpack
echo "  OK"

echo ""
echo "=== Step 2: BoringSSL ==="
if [ -f "$REPO/boringssl/CMakeLists.txt" ]; then
    echo "  Already cloned, skipping."
else
    git clone --depth=1 https://github.com/google/boringssl.git "$REPO/boringssl"
    echo "  OK"
fi

echo ""
echo "All dependencies ready. You can now run:"
echo "  docker compose build"
