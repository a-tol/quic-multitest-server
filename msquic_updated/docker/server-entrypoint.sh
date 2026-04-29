#!/bin/bash
set -e

CERT_DIR="/certs"
RESULTS_DIR="/results"
mkdir -p "$CERT_DIR" "$RESULTS_DIR"

echo "Generating self-signed TLS certificate..."
openssl req -nodes -new -x509 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.cert" \
    -subj "/CN=quicsample-server/O=msquic/C=US" \
    -days 3650 2>/dev/null
echo "Certificate generated."

# Keep a writer on the FIFO so the server's getchar() blocks indefinitely
# (quicsample -server waits for Enter before shutting down the listener)
FIFO=/tmp/server_stdin
mkfifo "$FIFO"
exec 3>"$FIFO"

echo "Starting quicsample server on UDP port 4567..."
quicsample -server \
    -cert_file:"$CERT_DIR/server.cert" \
    -key_file:"$CERT_DIR/server.key" \
    < "$FIFO" 2>&1 | tee "$RESULTS_DIR/server.log"
