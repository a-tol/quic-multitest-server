#!/bin/bash
set -e

SERVER_HOST="${SERVER_HOST:-server}"
SERVER_PORT="${SERVER_PORT:-4433}"
RETRIES=15
LOG_FILE=/results/client.log

mkdir -p /results

echo "Waiting for lsquic server at ${SERVER_HOST}:${SERVER_PORT} ..."

for i in $(seq 1 "$RETRIES"); do
    if http_client \
            -H  "$SERVER_HOST" \
            -s  "${SERVER_HOST}:${SERVER_PORT}" \
            -p  /100kb.bin \
            -K \
            -r  1 \
            >> "$LOG_FILE" 2>&1; then
        echo "=== Client connected and exchange completed successfully ==="
        exit 0
    fi
    echo "Attempt $i/$RETRIES failed, retrying in 2 s ..."
    sleep 2
done

echo "ERROR: client failed to connect after $RETRIES attempts" >&2
exit 1
