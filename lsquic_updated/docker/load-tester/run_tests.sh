#!/bin/bash
# QUIC / HTTP-3 load tester — uses lsquic http_client per-request and
# produces JSON + summary output compatible with the msquic test guide.
set -euo pipefail

SERVER_HOST="${SERVER_HOST:-server}"
SERVER_PORT="${SERVER_PORT:-4433}"
REPETITIONS="${REPETITIONS:-40}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

JSON_FILE="$RESULTS_DIR/load_results_${TIMESTAMP}.json"
SUMMARY_FILE="$RESULTS_DIR/load_summary_${TIMESTAMP}.txt"

PAYLOADS=(100kb.bin 1mb.bin 5mb.bin small_page.bin medium_page.bin large_page.bin)
TOTAL_REQS=$(( ${#PAYLOADS[@]} * REPETITIONS ))

mkdir -p "$RESULTS_DIR"

# ── wait for server ──────────────────────────────────────────────────────────
echo "Waiting for lsquic server at ${SERVER_HOST}:${SERVER_PORT} ..."
for i in $(seq 1 20); do
    if http_client -H "$SERVER_HOST" -s "${SERVER_HOST}:${SERVER_PORT}" \
                   -p /100kb.bin -K -r 1 2>/dev/null; then
        echo "Server is ready."
        break
    fi
    [ "$i" -eq 20 ] && { echo "ERROR: server not ready after 20 attempts" >&2; exit 1; }
    echo "  attempt $i/20 failed, retrying in 3 s ..."
    sleep 3
done

echo ""
echo "=========================================="
echo " LsQuic Load Tester"
echo " Mode       : quic"
echo " Protocols  : HTTP/3 (QUIC)"
echo " Server     : ${SERVER_HOST}:${SERVER_PORT}"
echo " Repetitions: ${REPETITIONS}"
echo " Total reqs : ${TOTAL_REQS}"
echo "=========================================="

REQUEST_NUM=0
FIRST_RECORD=true
echo "[" > "$JSON_FILE"

for payload in "${PAYLOADS[@]}"; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Payload: $payload"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for attempt in $(seq 1 "$REPETITIONS"); do
        (( REQUEST_NUM++ )) || true

        STATS_FILE=$(mktemp /tmp/lsquic_stats_XXXXXX.txt)

        # Run one request; -T writes the timing summary to STATS_FILE
        http_client \
            -H  "$SERVER_HOST" \
            -s  "${SERVER_HOST}:${SERVER_PORT}" \
            -p  "/$payload" \
            -K \
            -r  1 \
            -T  "$STATS_FILE" \
            2>/dev/null || true

        # ── parse stats ─────────────────────────────────────────────────────
        # Lines look like:
        #   time for connect: n: 1; min: 25.34 ms; ...
        #   time to 1st byte: n: 1; min: 26.78 ms; ...
        #   time for request: n: 1; min: 10.21 ms; ...
        #   downloaded 102400 application bytes in 0.036 seconds
        #   27.78 reqs/sec; 29109333 bytes/sec

        extract_min_ms() {
            grep -m1 "$1" "$STATS_FILE" 2>/dev/null \
                | grep -oP 'min: \K[0-9.]+' || echo "0"
        }

        TIME_CONNECT_MS=$(extract_min_ms "time for connect")
        TIME_TTFB_MS=$(extract_min_ms "time to 1st byte")
        TIME_TRANSFER_MS=$(extract_min_ms "time for request")

        # "downloaded N application bytes in T.TTT seconds"
        DL_LINE=$(grep -m1 "downloaded" "$STATS_FILE" 2>/dev/null \
                      || echo "downloaded 0 application bytes in 0 seconds")
        SIZE_BYTES=$(grep -oP 'downloaded \K[0-9]+' "$STATS_FILE" 2>/dev/null || echo "0")
        TIME_TOTAL_S=$(echo "$DL_LINE" | grep -oP 'in \K[0-9.]+' || echo "0")

        # "A.AA reqs/sec; B bytes/sec"
        SPEED_BPS=$(grep -oP '[0-9]+ bytes/sec' "$STATS_FILE" 2>/dev/null \
                        | grep -oP '[0-9]+' | head -1 || echo "0")

        rm -f "$STATS_FILE"

        # ── convert units ────────────────────────────────────────────────────
        ms2s() { awk "BEGIN {printf \"%.6f\", $1 / 1000}"; }
        TIME_CONNECT_S=$(ms2s "$TIME_CONNECT_MS")
        TIME_TTFB_S=$(ms2s   "$TIME_TTFB_MS")
        TIME_TRANSFER_S=$(ms2s "$TIME_TRANSFER_MS")

        SPEED_KBPS=$(awk "BEGIN {printf \"%.3f\", ${SPEED_BPS:-0} / 1024}")
        SPEED_MBPS=$(awk "BEGIN {printf \"%.3f\", ${SPEED_BPS:-0} / 1048576}")

        printf "  [%3d/%d] %-20s HTTP/3  attempt %02d/%d  ttfb=%.3fs  total=%.3fs\n" \
            "$REQUEST_NUM" "$TOTAL_REQS" "$payload" \
            "$attempt"     "$REPETITIONS" \
            "$TIME_TTFB_S" "${TIME_TOTAL_S:-0}"

        # ── append JSON record ───────────────────────────────────────────────
        if [ "$FIRST_RECORD" = true ]; then
            FIRST_RECORD=false
        else
            echo "," >> "$JSON_FILE"
        fi

        cat >> "$JSON_FILE" <<JSONEOF
  {
    "protocol": "HTTP/3",
    "payload": "$payload",
    "attempt": $attempt,
    "size_bytes": ${SIZE_BYTES:-0},
    "time_connect_s": $TIME_CONNECT_S,
    "time_ttfb_s": $TIME_TTFB_S,
    "time_transfer_s": $TIME_TRANSFER_S,
    "time_total_s": ${TIME_TOTAL_S:-0},
    "speed_Bps": ${SPEED_BPS:-0},
    "speed_KBps": $SPEED_KBPS,
    "speed_MBps": $SPEED_MBPS
  }
JSONEOF
    done
done

echo "]" >> "$JSON_FILE"

# ── symlinks for "latest" ─────────────────────────────────────────────────────
ln -sf "$(basename "$JSON_FILE")"    "$RESULTS_DIR/load_results_latest.json"
ln -sf "$(basename "$SUMMARY_FILE")" "$RESULTS_DIR/load_summary_latest.txt"

# ── summary (min / avg / max / p95 per payload) ───────────────────────────────
{
    echo "LsQuic QUIC/HTTP-3 Load Test Summary — $(date)"
    echo "================================================"
    echo ""
    for payload in "${PAYLOADS[@]}"; do
        printf "Payload: %s\n" "$payload"
        jq -r --arg p "$payload" '
            [ .[] | select(.payload == $p) | .time_total_s ] |
            if length == 0 then "  (no data)"
            else
              (sort) as $sorted |
              (length) as $n |
              "  min: \(min | (. * 1000 | round) / 1000)s" +
              "  avg: \((add / $n) | (. * 1000 | round) / 1000)s" +
              "  max: \(max | (. * 1000 | round) / 1000)s" +
              "  p95: \($sorted[($n * 0.95 | floor)] | (. * 1000 | round) / 1000)s"
            end
        ' "$JSON_FILE"
        echo ""
    done
} > "$SUMMARY_FILE"

echo ""
echo "Results saved:"
echo "  JSON    : $JSON_FILE"
echo "  Summary : $SUMMARY_FILE"
echo ""
cat "$SUMMARY_FILE"
