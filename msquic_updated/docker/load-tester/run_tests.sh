#!/bin/bash
# Downloads every payload over the selected protocol set, 40 times each by default.
# TEST_MODE=quic  → HTTP/2 + HTTP/3 (QUIC)  → load_results_*.csv/json
# TEST_MODE=tcp   → HTTP/1.1 + HTTP/2 (TCP) → tcp_results_*.csv/json

set -e

SERVER="${SERVER_URL:-https://h3-server:4433}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
REPETITIONS="${REPETITIONS:-40}"
CACERT="${CACERT:-/certs/server.crt}"
TEST_MODE="${TEST_MODE:-quic}"   # quic | tcp

RUN_TS=$(date -u +"%Y%m%dT%H%M%SZ")

# File prefix and protocol list differ by mode
if [ "$TEST_MODE" = "tcp" ]; then
    PREFIX="tcp_results"
    PROTOCOLS=(
        "--http1.1|HTTP/1.1"
        "--http2|HTTP/2"
    )
else
    PREFIX="load_results"
    PROTOCOLS=(
        "--http3-prior-knowledge|HTTP/3"
    )
fi

CSV="$RESULTS_DIR/${PREFIX}_${RUN_TS}.csv"
JSON="$RESULTS_DIR/${PREFIX}_${RUN_TS}.json"
SUMMARY="$RESULTS_DIR/${PREFIX%_results}_summary_${RUN_TS}.txt"

LATEST_CSV="$RESULTS_DIR/${PREFIX}_latest.csv"
LATEST_JSON="$RESULTS_DIR/${PREFIX}_latest.json"
LATEST_SUMMARY="$RESULTS_DIR/${PREFIX%_results}_summary_latest.txt"

PAYLOADS=(
    "100kb.bin"
    "1mb.bin"
    "5mb.bin"
    "small_page.bin"
    "medium_page.bin"
    "large_page.bin"
)

# All curl timing fields captured per request
CURL_FMT="\
size_download:%{size_download}\n\
http_version:%{http_version}\n\
http_code:%{http_code}\n\
time_namelookup:%{time_namelookup}\n\
time_connect:%{time_connect}\n\
time_appconnect:%{time_appconnect}\n\
time_pretransfer:%{time_pretransfer}\n\
time_starttransfer:%{time_starttransfer}\n\
time_total:%{time_total}\n\
speed_download:%{speed_download}\n\
num_connects:%{num_connects}\n\
num_redirects:%{num_redirects}\n"

TOTAL_REQUESTS=$(( ${#PAYLOADS[@]} * ${#PROTOCOLS[@]} * REPETITIONS ))
COMPLETED=0

mkdir -p "$RESULTS_DIR"

echo "=========================================="
echo " MsQuic Load Tester"
echo " Mode       : $TEST_MODE"
echo " Server     : $SERVER"
echo " Payloads   : ${#PAYLOADS[@]}"
echo " Protocols  : $(IFS=', '; echo "${PROTOCOLS[*]}" | sed 's/[^|]*|//g')"
echo " Repetitions: $REPETITIONS per payload per protocol"
echo " Total reqs : $TOTAL_REQUESTS"
echo " Run ID     : $RUN_TS"
echo " Results    : $RESULTS_DIR"
echo "=========================================="
echo ""

# ── wait for server ─────────────────────────────────────────────────────────
echo "Waiting for h3-server to be ready..."
for i in $(seq 1 30); do
    if curl -sk --cacert "$CACERT" "$SERVER" -o /dev/null 2>/dev/null; then
        echo "Server is up."
        echo ""
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: server did not respond after 60s. Exiting."
        exit 1
    fi
    echo "  attempt $i/30 — retrying in 2s..."
    sleep 2
done

# ── CSV header ──────────────────────────────────────────────────────────────
cat > "$CSV" <<'HDR'
run_id,timestamp,protocol,http_version,payload,attempt,http_code,size_bytes,time_namelookup_s,time_connect_s,time_appconnect_s,time_pretransfer_s,time_starttransfer_s,time_total_s,time_to_last_byte_s,body_transfer_s,speed_Bps,speed_KBps,speed_MBps,num_connects,num_redirects
HDR

# ── JSON array start ─────────────────────────────────────────────────────────
echo "[" > "$JSON"
FIRST_JSON=true

# ── core measurement function ────────────────────────────────────────────────
run_one() {
    local proto_flag="$1"
    local proto_label="$2"
    local payload="$3"
    local attempt="$4"

    local raw
    raw=$(curl -sk \
        --cacert "$CACERT" \
        $proto_flag \
        -o /dev/null \
        -w "$CURL_FMT" \
        "$SERVER/$payload" 2>/dev/null) || true

    local size http_ver http_code t_dns t_conn t_tls t_pre t_ttfb t_total speed n_conn n_redir
    size=$(      printf '%s' "$raw" | awk -F: '/^size_download:/      {print $2}')
    http_ver=$(  printf '%s' "$raw" | awk -F: '/^http_version:/       {print $2}')
    http_code=$( printf '%s' "$raw" | awk -F: '/^http_code:/          {print $2}')
    t_dns=$(     printf '%s' "$raw" | awk -F: '/^time_namelookup:/    {print $2}')
    t_conn=$(    printf '%s' "$raw" | awk -F: '/^time_connect:/       {print $2}')
    t_tls=$(     printf '%s' "$raw" | awk -F: '/^time_appconnect:/    {print $2}')
    t_pre=$(     printf '%s' "$raw" | awk -F: '/^time_pretransfer:/   {print $2}')
    t_ttfb=$(    printf '%s' "$raw" | awk -F: '/^time_starttransfer:/ {print $2}')
    t_total=$(   printf '%s' "$raw" | awk -F: '/^time_total:/         {print $2}')
    speed=$(     printf '%s' "$raw" | awk -F: '/^speed_download:/     {print $2}')
    n_conn=$(    printf '%s' "$raw" | awk -F: '/^num_connects:/       {print $2}')
    n_redir=$(   printf '%s' "$raw" | awk -F: '/^num_redirects:/      {print $2}')

    # default zeros
    size=${size:-0}; http_ver=${http_ver:-0}; http_code=${http_code:-0}
    t_dns=${t_dns:-0}; t_conn=${t_conn:-0}; t_tls=${t_tls:-0}
    t_pre=${t_pre:-0}; t_ttfb=${t_ttfb:-0}; t_total=${t_total:-0}
    speed=${speed:-0}; n_conn=${n_conn:-0}; n_redir=${n_redir:-0}

    # time_to_last_byte  = total time from request start to last byte received (= time_total)
    # body_transfer      = pure data transfer time, excluding all connection/protocol overhead
    local t_ttlb t_body
    t_ttlb=$t_total
    t_body=$(awk "BEGIN {printf \"%.6f\", $t_total - $t_ttfb}")

    local speed_kb speed_mb
    speed_kb=$(awk "BEGIN {printf \"%.3f\", $speed / 1024}")
    speed_mb=$(awk "BEGIN {printf \"%.3f\", $speed / 1048576}")

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # CSV row
    printf '%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$RUN_TS" "$ts" "$proto_label" "$http_ver" "$payload" \
        "$attempt" "$http_code" "$size" \
        "$t_dns" "$t_conn" "$t_tls" "$t_pre" "$t_ttfb" "$t_total" \
        "$t_ttlb" "$t_body" \
        "$speed" "$speed_kb" "$speed_mb" "$n_conn" "$n_redir" >> "$CSV"

    # JSON row
    if [ "$FIRST_JSON" = true ]; then
        FIRST_JSON=false
    else
        printf ',\n' >> "$JSON"
    fi
    cat >> "$JSON" <<EOF
  {
    "run_id": "$RUN_TS",
    "timestamp": "$ts",
    "protocol": "$proto_label",
    "http_version": "$http_ver",
    "payload": "$payload",
    "attempt": $attempt,
    "http_code": $http_code,
    "size_bytes": $size,
    "time_namelookup_s": $t_dns,
    "time_connect_s": $t_conn,
    "time_appconnect_s": $t_tls,
    "time_pretransfer_s": $t_pre,
    "time_starttransfer_s": $t_ttfb,
    "time_total_s": $t_total,
    "time_to_last_byte_s": $t_ttlb,
    "body_transfer_s": $t_body,
    "speed_Bps": $speed,
    "speed_KBps": $speed_kb,
    "speed_MBps": $speed_mb,
    "num_connects": $n_conn,
    "num_redirects": $n_redir
  }
EOF

    COMPLETED=$(( COMPLETED + 1 ))
    printf "  [%3d/%3d] %-20s  %-6s  attempt %02d/%02d  HTTP/%-3s  ttfb=%-8s  total=%-8s  %s MBps\n" \
        "$COMPLETED" "$TOTAL_REQUESTS" \
        "$payload" "$proto_label" "$attempt" "$REPETITIONS" \
        "$http_ver" "$t_ttfb" "$t_total" "$speed_mb"
}

# ── main loop ────────────────────────────────────────────────────────────────
for payload in "${PAYLOADS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Payload: $payload"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for proto_entry in "${PROTOCOLS[@]}"; do
        proto_flag="${proto_entry%%|*}"
        proto_label="${proto_entry##*|}"
        echo "  ── $proto_label ──"
        for i in $(seq 1 "$REPETITIONS"); do
            run_one "$proto_flag" "$proto_label" "$payload" "$i"
        done
        echo ""
    done
done

printf ']\n' >> "$JSON"

# ── summary: min / avg / max / p95 per payload+protocol ─────────────────────
{
    echo "========================================================"
    echo " Load Test Summary"
    echo " Run    : $RUN_TS"
    echo " Server : $SERVER"
    echo " Reps   : $REPETITIONS per payload per protocol"
    echo " Total  : $TOTAL_REQUESTS requests"
    echo "========================================================"
    echo ""

    for section in "time_total_s:Total Transfer Time (s)" \
                   "time_starttransfer_s:Time To First Byte (s)" \
                   "time_appconnect_s:TLS Handshake Time (s)" \
                   "speed_MBps:Download Speed (MB/s)"; do

        col_name="${section%%:*}"
        col_title="${section##*:}"

        echo "── $col_title ──────────────────────────────────────"
        printf "  %-22s  %-8s  %8s  %8s  %8s  %8s  %8s\n" \
            "Payload" "Protocol" "Min" "Avg" "Max" "P95" "Samples"
        printf "  %-22s  %-8s  %8s  %8s  %8s  %8s  %8s\n" \
            "──────────────────────" "────────" "────────" \
            "────────" "────────" "────────" "───────"

        # map column name to CSV column index (1-based)
        # CSV: run_id(1) ts(2) protocol(3) http_version(4) payload(5) attempt(6)
        #      http_code(7) size_bytes(8) t_dns(9) t_conn(10) t_tls(11)
        #      t_pre(12) t_ttfb(13) t_total(14) speed_Bps(15) speed_KBps(16)
        #      speed_MBps(17) n_conn(18) n_redir(19)
        local col_idx
        case "$col_name" in
            time_namelookup_s)   col_idx=9  ;;
            time_connect_s)      col_idx=10 ;;
            time_appconnect_s)   col_idx=11 ;;
            time_pretransfer_s)  col_idx=12 ;;
            time_starttransfer_s) col_idx=13 ;;
            time_total_s)        col_idx=14 ;;
            speed_MBps)          col_idx=17 ;;
            *)                   col_idx=14 ;;
        esac

        tail -n +2 "$CSV" | awk -F',' -v ci="$col_idx" '
        {
            key = $5 SUBSEP $3          # payload + protocol
            val = $ci + 0
            sum[key]  += val
            count[key]++
            # store all values for percentile
            vals[key][count[key]] = val
            if (count[key] == 1 || val < mn[key]) mn[key] = val
            if (count[key] == 1 || val > mx[key]) mx[key] = val
        }
        END {
            for (k in count) {
                n = count[k]
                avg = sum[k] / n
                # sort values for p95
                m = n
                for (i = 1; i <= m; i++) arr[i] = vals[k][i]
                # bubble sort (small n)
                for (i = 1; i <= m; i++)
                    for (j = i+1; j <= m; j++)
                        if (arr[j] < arr[i]) { t=arr[i]; arr[i]=arr[j]; arr[j]=t }
                p95_idx = int(0.95 * m + 0.5)
                if (p95_idx < 1) p95_idx = 1
                if (p95_idx > m) p95_idx = m
                p95 = arr[p95_idx]
                split(k, a, SUBSEP)
                printf "  %-22s  %-8s  %8.4f  %8.4f  %8.4f  %8.4f  %8d\n",
                    a[1], a[2], mn[k], avg, mx[k], p95, n
            }
        }' | sort
        echo ""
    done
} | tee "$SUMMARY"

# symlinks to latest run
ln -sf "$(basename "$CSV")"     "$LATEST_CSV"
ln -sf "$(basename "$JSON")"    "$LATEST_JSON"
ln -sf "$(basename "$SUMMARY")" "$LATEST_SUMMARY"

echo "=========================================="
echo " Files written:"
echo "   $CSV"
echo "   $JSON"
echo "   $SUMMARY"
echo ""
echo " Latest symlinks:"
echo "   $LATEST_CSV"
echo "   $LATEST_JSON"
echo "   $LATEST_SUMMARY"
echo "=========================================="
