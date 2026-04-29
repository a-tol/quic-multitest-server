#!/usr/bin/env bash
# Start the lsquic HTTP/3 server natively on macOS.
# Usage: ./scripts/start-server.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$REPO/build-mac/bin/http_server}"
CERT_DIR="/tmp/lsquic-certs"
PAYLOADS_DIR="${PAYLOADS_DIR:-$REPO/payloads}"
PORT="${PORT:-4433}"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: http_server not found at $BINARY"
    echo "Run the build steps first (cmake + make in build-mac/)."
    exit 1
fi

if [ ! -d "$PAYLOADS_DIR" ] || [ -z "$(ls -A "$PAYLOADS_DIR")" ]; then
    echo "ERROR: No payload files found in $PAYLOADS_DIR"
    echo "Run: ./scripts/generate-payloads.sh"
    exit 1
fi

mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
    echo "Generating ECDSA TLS certificate ..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$CERT_DIR/server.key" \
        -out    "$CERT_DIR/server.crt" \
        -days 365 -nodes \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    echo "Certificate generated at $CERT_DIR"
fi

echo ""
echo "======================================"
echo " LsQuic HTTP/3 Server"
echo " Listen  : 0.0.0.0:${PORT} (UDP)"
echo " Root    : $PAYLOADS_DIR"
echo " Versions: h3-29, h3"
echo "======================================"
echo ""
ls -lh "$PAYLOADS_DIR"
echo ""

exec "$BINARY" \
    -s "0.0.0.0:${PORT}" \
    -c "localhost,$CERT_DIR/server.crt,$CERT_DIR/server.key" \
    -r "$PAYLOADS_DIR" \
    -o version=h3-29 \
    -o version=h3
