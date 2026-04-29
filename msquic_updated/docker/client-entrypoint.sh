#!/bin/bash
set -e

TARGET="${TARGET:-server}"
PORT="${PORT:-4567}"
RESULTS_DIR="/results"
MAX_RETRIES="${MAX_RETRIES:-15}"
RETRY_DELAY="${RETRY_DELAY:-2}"

mkdir -p "$RESULTS_DIR"

echo "Client will connect to $TARGET:$PORT"
echo "Waiting for server to be ready..."

for i in $(seq 1 "$MAX_RETRIES"); do
    echo "Attempt $i/$MAX_RETRIES: connecting to $TARGET..."

    # Capture output; quicsample exits 0 even on failure so check the output text
    OUTPUT=$(quicsample -client -unsecure -target:"$TARGET" 2>&1)
    echo "$OUTPUT" | tee -a "$RESULTS_DIR/client.log"

    if echo "$OUTPUT" | grep -q "\[conn\].*Connected"; then
        echo ""
        echo "=== Client connected and exchange completed successfully ==="
        echo "Results saved to $RESULTS_DIR/client.log"
        exit 0
    fi

    echo "Connection not established yet, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done

echo "ERROR: Failed to connect to $TARGET after $MAX_RETRIES attempts."
exit 1
