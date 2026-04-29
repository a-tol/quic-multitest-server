#!/usr/bin/env bash
# Run QUIC/HTTP-3 load test using the native lsquic http_client.
# Saves results as JSON, CSV, and TXT summary.
#
# Usage:
#   ./scripts/run-load-test.sh
#   REPETITIONS=20 ./scripts/run-load-test.sh
#   SERVER_PORT=4434 REPETITIONS=5 ./scripts/run-load-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$REPO/build-mac/bin/http_client}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_SNI="${SERVER_SNI:-localhost}"
SERVER_PORT="${SERVER_PORT:-4433}"
REPETITIONS="${REPETITIONS:-10}"
IFS=' ' read -r -a PAYLOADS <<< "${PAYLOADS:-100kb.bin 1mb.bin 5mb.bin small_page.bin medium_page.bin large_page.bin}"

RESULTS_DIR="$REPO/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
JSON_FILE="$RESULTS_DIR/results_${TIMESTAMP}.json"
CSV_FILE="$RESULTS_DIR/results_${TIMESTAMP}.csv"
TXT_FILE="$RESULTS_DIR/summary_${TIMESTAMP}.txt"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: http_client not found at $BINARY"
    exit 1
fi

# ── wait for server ───────────────────────────────────────────────────────────
echo "Checking server at ${SERVER_HOST}:${SERVER_PORT} ..."
READY=false
for i in $(seq 1 15); do
    TMP=$(mktemp /tmp/lsquic_chk_XXXXXX.txt)
    if "$BINARY" -H "$SERVER_SNI" -s "${SERVER_HOST}:${SERVER_PORT}" \
            -p /100kb.bin -K -r 1 -o version=h3-29 -o version=h3 \
            -T "$TMP" 2>/dev/null; then
        rm -f "$TMP"
        READY=true
        break
    fi
    rm -f "$TMP"
    echo "  attempt $i/15 — retrying in 2s ..."
    sleep 2
done

if [ "$READY" = false ]; then
    echo "ERROR: server not reachable. Start it with: ./scripts/start-server.sh"
    exit 1
fi
echo "Server is ready."

TOTAL_REQS=$(( ${#PAYLOADS[@]} * REPETITIONS ))

echo ""
echo "=========================================="
echo " LsQuic Native Load Test"
echo " Server     : ${SERVER_HOST}:${SERVER_PORT}"
echo " Protocol   : QUIC / HTTP-3"
echo " Repetitions: ${REPETITIONS} per payload"
echo " Total reqs : ${TOTAL_REQS}"
echo "=========================================="

# ── CSV header ────────────────────────────────────────────────────────────────
echo "request_num,payload,attempt,protocol,size_bytes,time_connect_s,time_ttfb_s,time_ttlb_s,time_total_s,speed_Bps,speed_KBps,speed_MBps" \
    > "$CSV_FILE"

# ── JSON opening ──────────────────────────────────────────────────────────────
echo "[" > "$JSON_FILE"
FIRST_RECORD=true
REQUEST_NUM=0

for payload in "${PAYLOADS[@]}"; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Payload: $payload"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for attempt in $(seq 1 "$REPETITIONS"); do
        REQUEST_NUM=$(( REQUEST_NUM + 1 ))
        STATS=$(mktemp /tmp/lsquic_stats_XXXXXX.txt)

        "$BINARY" \
            -H "$SERVER_SNI" \
            -s "${SERVER_HOST}:${SERVER_PORT}" \
            -p "/$payload" \
            -r 1 \
            -o version=h3-29 -o version=h3 \
            -T "$STATS" \
            >/dev/null 2>/dev/null || true

        # ── parse (macOS awk/grep -E compatible) ─────────────────────────────
        # "time for connect: n: 1; min: X.XX ms; ..."
        TIME_CONNECT_MS=$(grep "time for connect" "$STATS" 2>/dev/null \
            | grep -oE 'min: [0-9.]+' | awk '{print $2}')
        TIME_TTFB_MS=$(grep "time to 1st byte" "$STATS" 2>/dev/null \
            | grep -oE 'min: [0-9.]+' | awk '{print $2}')
        TIME_TTLB_MS=$(grep "time for request" "$STATS" 2>/dev/null \
            | grep -oE 'min: [0-9.]+' | awk '{print $2}')

        # "downloaded N application bytes in T.TTT seconds"
        DL_LINE=$(grep "downloaded" "$STATS" 2>/dev/null \
            || echo "downloaded 0 application bytes in 0 seconds")
        SIZE_BYTES=$(echo "$DL_LINE" | awk '{print $2}')
        TIME_TOTAL_S=$(echo "$DL_LINE" | awk '{print $6}')

        # "A.AA reqs/sec; B bytes/sec"
        SPEED_BPS=$(grep "bytes/sec" "$STATS" 2>/dev/null \
            | awk '{print $3}' || echo "0")

        rm -f "$STATS"

        # defaults for empty / failed run
        TIME_CONNECT_MS="${TIME_CONNECT_MS:-0}"
        TIME_TTFB_MS="${TIME_TTFB_MS:-0}"
        TIME_TTLB_MS="${TIME_TTLB_MS:-0}"
        SIZE_BYTES="${SIZE_BYTES:-0}"
        TIME_TOTAL_S="${TIME_TOTAL_S:-0}"
        SPEED_BPS="${SPEED_BPS:-0}"

        # ── unit conversions ──────────────────────────────────────────────────
        TIME_CONNECT_S=$(awk "BEGIN{printf \"%.6f\", $TIME_CONNECT_MS/1000}")
        TIME_TTFB_S=$(awk    "BEGIN{printf \"%.6f\", $TIME_TTFB_MS/1000}")
        TIME_TTLB_S=$(awk    "BEGIN{printf \"%.6f\", $TIME_TTLB_MS/1000}")
        SPEED_KBPS=$(awk     "BEGIN{printf \"%.3f\",  $SPEED_BPS/1024}")
        SPEED_MBPS=$(awk     "BEGIN{printf \"%.3f\",  $SPEED_BPS/1048576}")

        printf "  [%3d/%d] %-20s  attempt %02d/%d  ttfb=%.3fs  total=%.3fs  %.2f MB/s\n" \
            "$REQUEST_NUM" "$TOTAL_REQS" "$payload" \
            "$attempt" "$REPETITIONS" \
            "$TIME_TTFB_S" "$TIME_TOTAL_S" "$SPEED_MBPS"

        # ── CSV row ───────────────────────────────────────────────────────────
        echo "$REQUEST_NUM,$payload,$attempt,QUIC/HTTP3,$SIZE_BYTES,$TIME_CONNECT_S,$TIME_TTFB_S,$TIME_TTLB_S,$TIME_TOTAL_S,$SPEED_BPS,$SPEED_KBPS,$SPEED_MBPS" \
            >> "$CSV_FILE"

        # ── JSON record ───────────────────────────────────────────────────────
        [ "$FIRST_RECORD" = true ] && FIRST_RECORD=false || echo "," >> "$JSON_FILE"

        cat >> "$JSON_FILE" <<JSONEOF
  {
    "request_num": $REQUEST_NUM,
    "payload":     "$payload",
    "attempt":     $attempt,
    "protocol":    "QUIC/HTTP3",
    "size_bytes":  $SIZE_BYTES,
    "time_connect_s":  $TIME_CONNECT_S,
    "time_ttfb_s":     $TIME_TTFB_S,
    "time_ttlb_s":     $TIME_TTLB_S,
    "time_total_s":    $TIME_TOTAL_S,
    "speed_Bps":  $SPEED_BPS,
    "speed_KBps": $SPEED_KBPS,
    "speed_MBps": $SPEED_MBPS
  }
JSONEOF
    done
done

echo "]" >> "$JSON_FILE"

# ── symlinks ──────────────────────────────────────────────────────────────────
ln -sf "$(basename "$JSON_FILE")" "$RESULTS_DIR/results_latest.json"
ln -sf "$(basename "$CSV_FILE")"  "$RESULTS_DIR/results_latest.csv"
ln -sf "$(basename "$TXT_FILE")"  "$RESULTS_DIR/summary_latest.txt"

# ── TXT summary (min / avg / max / p95 per payload) ───────────────────────────
{
    printf "LsQuic QUIC/HTTP-3 Load Test Summary\n"
    printf "=====================================\n"
    printf "Server : %s:%s\n" "$SERVER_HOST" "$SERVER_PORT"
    printf "Date   : %s\n"    "$(date)"
    printf "Reps   : %s per payload\n\n" "$REPETITIONS"
    printf "%-20s | %8s | %8s | %8s | %8s | %10s\n" \
        "Payload" "min(s)" "avg(s)" "max(s)" "p95(s)" "avg MB/s"
    printf "%-20s-+-%8s-+-%8s-+-%8s-+-%8s-+-%10s\n" \
        "--------------------" "--------" "--------" "--------" "--------" "----------"

    for payload in "${PAYLOADS[@]}"; do
        # collect time_total_s values for this payload (field 9, 1-indexed from CSV)
        VALS=$(awk -F',' -v p="$payload" 'NR>1 && $2==p {print $9}' "$CSV_FILE")
        SPEED_VALS=$(awk -F',' -v p="$payload" 'NR>1 && $2==p {print $12}' "$CSV_FILE")

        if [ -z "$VALS" ]; then
            printf "%-20s | %8s\n" "$payload" "no data"
            continue
        fi

        STATS=$(echo "$VALS" | sort -n | awk '
        BEGIN { n=0; sum=0; mn=999999; mx=0 }
        {
            n++; sum += $1
            if ($1 < mn) mn=$1
            if ($1 > mx) mx=$1
            vals[n] = $1
        }
        END {
            avg = sum / n
            p95 = vals[int(n*0.95)+1]
            if (p95=="") p95=vals[n]
            printf "%.6f %.6f %.6f %.6f", mn, avg, mx, p95
        }')

        AVG_SPEED=$(echo "$SPEED_VALS" | awk '{sum+=$1; n++} END{if(n>0) printf "%.3f", sum/n; else print "0"}')

        MIN_S=$(echo "$STATS" | awk '{print $1}')
        AVG_S=$(echo "$STATS" | awk '{print $2}')
        MAX_S=$(echo "$STATS" | awk '{print $3}')
        P95_S=$(echo "$STATS" | awk '{print $4}')

        printf "%-20s | %8.4f | %8.4f | %8.4f | %8.4f | %10.3f\n" \
            "$payload" "$MIN_S" "$AVG_S" "$MAX_S" "$P95_S" "$AVG_SPEED"
    done
} > "$TXT_FILE"

echo ""
echo "Results saved:"
printf "  JSON : %s\n" "$JSON_FILE"
printf "  CSV  : %s\n" "$CSV_FILE"
printf "  TXT  : %s\n" "$TXT_FILE"
echo ""
cat "$TXT_FILE"
