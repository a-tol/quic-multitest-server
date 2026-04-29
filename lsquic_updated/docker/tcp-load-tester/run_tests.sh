#!/bin/bash
# TCP load tester — uses curl to test HTTP/1.1 and HTTP/2 over TLS (nginx).
set -euo pipefail

SERVER_HOST="${SERVER_HOST:-tcp-server}"
SERVER_PORT="${SERVER_PORT:-8080}"
REPETITIONS="${REPETITIONS:-40}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

JSON_FILE="$RESULTS_DIR/tcp_results_${TIMESTAMP}.json"
SUMMARY_FILE="$RESULTS_DIR/tcp_summary_${TIMESTAMP}.txt"

PAYLOADS=(100kb.bin 1mb.bin 5mb.bin small_page.bin medium_page.bin large_page.bin)
PROTOCOLS=("HTTP/1.1" "HTTP/2")
CURL_FLAGS=("--http1.1" "--http2")
TOTAL_REQS=$(( ${#PAYLOADS[@]} * ${#PROTOCOLS[@]} * REPETITIONS ))

BASE_URL="https://${SERVER_HOST}:${SERVER_PORT}"

mkdir -p "$RESULTS_DIR"

# curl write-out format — one JSON object per request
CURL_FORMAT='{
  "http_code":             %{http_code},
  "size_bytes":            %{size_download},
  "time_namelookup_s":     %{time_namelookup},
  "time_connect_s":        %{time_connect},
  "time_appconnect_s":     %{time_appconnect},
  "time_pretransfer_s":    %{time_pretransfer},
  "time_starttransfer_s":  %{time_starttransfer},
  "time_total_s":          %{time_total},
  "speed_Bps":             %{speed_download}
}'

# ── wait for TCP server ───────────────────────────────────────────────────────
echo "Waiting for nginx at ${SERVER_HOST}:${SERVER_PORT} ..."
for i in $(seq 1 20); do
    if curl -sk --max-time 3 "${BASE_URL}/100kb.bin" -o /dev/null; then
        echo "Server is ready."
        break
    fi
    [ "$i" -eq 20 ] && { echo "ERROR: TCP server not ready after 20 attempts" >&2; exit 1; }
    echo "  attempt $i/20 failed, retrying in 3 s ..."
    sleep 3
done

echo ""
echo "=========================================="
echo " LsQuic Load Tester"
echo " Mode       : tcp"
echo " Protocols  : HTTP/1.1, HTTP/2"
echo " Server     : ${BASE_URL}"
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

    for proto_idx in "${!PROTOCOLS[@]}"; do
        proto="${PROTOCOLS[$proto_idx]}"
        curl_flag="${CURL_FLAGS[$proto_idx]}"

        for attempt in $(seq 1 "$REPETITIONS"); do
            (( REQUEST_NUM++ )) || true

            TIMING=$(curl -sk \
                $curl_flag \
                --insecure \
                --max-time 60 \
                -o /dev/null \
                -w "$CURL_FORMAT" \
                "${BASE_URL}/${payload}" 2>/dev/null || echo '{}')

            HTTP_CODE=$(echo "$TIMING"    | jq -r '.http_code        // 0')
            SIZE_BYTES=$(echo "$TIMING"   | jq -r '.size_bytes       // 0')
            TIME_TOTAL=$(echo "$TIMING"   | jq -r '.time_total_s     // 0')
            TIME_TTFB=$(echo "$TIMING"    | jq -r '.time_starttransfer_s // 0')
            SPEED_BPS=$(echo "$TIMING"    | jq -r '.speed_Bps        // 0' | awk '{printf "%d", $1}')
            SPEED_KBPS=$(awk "BEGIN {printf \"%.3f\", ${SPEED_BPS} / 1024}")
            SPEED_MBPS=$(awk "BEGIN {printf \"%.3f\", ${SPEED_BPS} / 1048576}")
            BODY_XFER=$(echo "$TIMING"    | jq -r '(.time_total_s - .time_starttransfer_s) // 0')

            printf "  [%3d/%d] %-20s %-8s  attempt %02d/%d  ttfb=%.3fs  total=%.3fs\n" \
                "$REQUEST_NUM" "$TOTAL_REQS" "$payload" \
                "$proto" "$attempt" "$REPETITIONS" \
                "$TIME_TTFB" "$TIME_TOTAL"

            if [ "$FIRST_RECORD" = true ]; then
                FIRST_RECORD=false
            else
                echo "," >> "$JSON_FILE"
            fi

            cat >> "$JSON_FILE" <<JSONEOF
  {
    "protocol": "$proto",
    "payload": "$payload",
    "attempt": $attempt,
    "http_code": $HTTP_CODE,
    "size_bytes": $SIZE_BYTES,
    "time_namelookup_s":    $(echo "$TIMING" | jq -r '.time_namelookup_s    // 0'),
    "time_connect_s":       $(echo "$TIMING" | jq -r '.time_connect_s       // 0'),
    "time_appconnect_s":    $(echo "$TIMING" | jq -r '.time_appconnect_s    // 0'),
    "time_pretransfer_s":   $(echo "$TIMING" | jq -r '.time_pretransfer_s   // 0'),
    "time_starttransfer_s": $(echo "$TIMING" | jq -r '.time_starttransfer_s // 0'),
    "time_total_s":         $TIME_TOTAL,
    "time_ttlb_s":          $TIME_TOTAL,
    "body_transfer_s":      $BODY_XFER,
    "speed_Bps":            $SPEED_BPS,
    "speed_KBps":           $SPEED_KBPS,
    "speed_MBps":           $SPEED_MBPS
  }
JSONEOF
        done
    done
done

echo "]" >> "$JSON_FILE"

ln -sf "$(basename "$JSON_FILE")"    "$RESULTS_DIR/tcp_results_latest.json"
ln -sf "$(basename "$SUMMARY_FILE")" "$RESULTS_DIR/tcp_summary_latest.txt"

# ── summary (min / avg / max / p95 per payload × protocol) ───────────────────
{
    echo "LsQuic TCP Load Test Summary — $(date)"
    echo "======================================="
    echo ""
    for payload in "${PAYLOADS[@]}"; do
        for proto in "${PROTOCOLS[@]}"; do
            printf "Payload: %-20s  Protocol: %s\n" "$payload" "$proto"
            jq -r --arg p "$payload" --arg pr "$proto" '
                [ .[] | select(.payload == $p and .protocol == $pr) | .time_total_s ] |
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
    done
} > "$SUMMARY_FILE"

echo ""
echo "Results saved:"
echo "  JSON    : $JSON_FILE"
echo "  Summary : $SUMMARY_FILE"
echo ""
cat "$SUMMARY_FILE"
