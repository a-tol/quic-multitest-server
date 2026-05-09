#!/bin/sh
# HTTP/3 (QUIC) load tester.
# Outputs results in both JSON and CSV formats.

SERVER_H3="https://server:8444"
RESULTS_DIR="${RESULTS_DIR:-/results}"
REPETITIONS="${REPETITIONS:-40}"
PAYLOADS="100kb.bin 1mb.bin 5mb.bin small_page.bin medium_page.bin large_page.bin"
NUM_PAYLOADS=6
TOTAL=$((REPETITIONS * NUM_PAYLOADS))

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TSV_FILE="/tmp/raw_h3_${TIMESTAMP}.tsv"
JSON_FILE="${RESULTS_DIR}/load_results_${TIMESTAMP}.json"
CSV_FILE="${RESULTS_DIR}/load_results_${TIMESTAMP}.csv"
SUMMARY_FILE="${RESULTS_DIR}/load_summary_${TIMESTAMP}.txt"
PY_SCRIPT="/tmp/gen_output_${TIMESTAMP}.py"

mkdir -p "$RESULTS_DIR"

# ── curl version + HTTP/3 gate ─────────────────────────────────────────────
echo "[load-tester] curl version:"
/usr/local/bin/curl --version
echo ""

if ! /usr/local/bin/curl --version | grep -qi "HTTP3"; then
    echo "FATAL: curl was built without HTTP/3 support. Rebuild the image."
    exit 1
fi

# ── wait for server ────────────────────────────────────────────────────────
echo "[load-tester] Waiting for h2o server..."
attempts=0
while true; do
    /usr/local/bin/curl -sf --connect-timeout 3 \
        "http://server:8080/1mb.bin" -o /dev/null 2>/dev/null && break
    attempts=$((attempts + 1))
    [ "$attempts" -ge 30 ] && { echo "ERROR: server not ready."; exit 1; }
    sleep 2
done
echo "[load-tester] Server ready."
echo ""

# ── banner ─────────────────────────────────────────────────────────────────
echo "=========================================="
echo " h2o Load Tester"
echo " Mode       : quic"
echo " Protocols  : HTTP/3"
echo " Repetitions: ${REPETITIONS}"
echo " Total reqs : ${TOTAL}"
echo "=========================================="
echo ""

# ── verbose H3 diagnostic (one request) ───────────────────────────────────
echo "[load-tester] --- H3 connectivity diagnostic ---"
/usr/local/bin/curl -v --http3 --insecure --max-time 15 \
    "${SERVER_H3}/100kb.bin" -o /dev/null 2>&1 || true
echo "[load-tester] --- end diagnostic ---"
echo ""

# ── TSV header ─────────────────────────────────────────────────────────────
# url is captured per-request so it appears in every output record
printf "protocol\turl\thttp_version\tpayload\tattempt\thttp_code\tsize_download\ttime_namelookup\ttime_connect\ttime_appconnect\ttime_pretransfer\ttime_starttransfer\ttime_total\tspeed_download\tnum_connects\tnum_redirects\n" \
    > "$TSV_FILE"

CURL_FMT="%{http_code}\t%{http_version}\t%{size_download}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_pretransfer}\t%{time_starttransfer}\t%{time_total}\t%{speed_download}\t%{num_connects}\t%{num_redirects}"

# ── requests ───────────────────────────────────────────────────────────────
req_num=0
for payload in $PAYLOADS; do
    url="${SERVER_H3}/${payload}"

    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "  Payload : %s\n" "$payload"
    printf "  URL     : %s\n" "$url"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

    attempt=1
    while [ "$attempt" -le "$REPETITIONS" ]; do
        req_num=$((req_num + 1))

        # shellcheck disable=SC2086
        raw=$(/usr/local/bin/curl -o /dev/null -s -w "$CURL_FMT" \
                  --http3 --insecure \
                  --connect-timeout 10 --max-time 120 \
                  "$url" 2>/dev/null) \
            || raw=$(printf "000\t\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0")

        http_code=$(printf "%s" "$raw" | awk -F'\t' '{print $1}')
        http_ver=$(printf  "%s" "$raw" | awk -F'\t' '{print $2}')
        ttfb=$(printf      "%s" "$raw" | awk -F'\t' '{printf "%.3f", $8}')
        total=$(printf     "%s" "$raw" | awk -F'\t' '{printf "%.3f", $9}')

        printf "  [%3d/%d] %-18s HTTP/3  attempt %02d/%d  http_version=%s  http_code=%s  ttfb=%ss  total=%ss\n" \
            "$req_num" "$TOTAL" "$payload" \
            "$attempt" "$REPETITIONS" \
            "${http_ver:-?}" "$http_code" "$ttfb" "$total"

        # Write: protocol | url | raw curl fields
        printf "HTTP/3\t%s\t%s\n" "$url" "$raw" >> "$TSV_FILE"
        attempt=$((attempt + 1))
    done
    echo ""
done

# ── Python: TSV → JSON + CSV + summary ────────────────────────────────────
cat > "$PY_SCRIPT" << 'PYEOF'
import csv, json, statistics, sys
from pathlib import Path

tsv_file, json_file, csv_file, summary_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

PAYLOAD_ORDER = ["100kb.bin","1mb.bin","5mb.bin","small_page.bin","medium_page.bin","large_page.bin"]

CSV_FIELDS = [
    "url","protocol","http_version","payload","attempt","http_code","size_bytes",
    "time_namelookup_s","time_connect_s","time_appconnect_s",
    "time_pretransfer_s","time_starttransfer_s","time_total_s",
    "time_to_last_byte_s","body_transfer_s",
    "speed_Bps","speed_KBps","speed_MBps","num_connects","num_redirects",
]

records = []
with open(tsv_file, newline="") as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        def f(k, default=0.0): return float(row.get(k) or default)
        def i(k, default=0):   return int(float(row.get(k) or default))
        speed_bps        = f("speed_download")
        time_pretransfer = f("time_pretransfer")
        time_total       = f("time_total")
        records.append({
            "url":                   row.get("url", ""),
            "protocol":              row.get("protocol", ""),
            "http_version":          row.get("http_version", ""),
            "payload":               row.get("payload", ""),
            "attempt":               i("attempt"),
            "http_code":             i("http_code"),
            "size_bytes":            i("size_download"),
            "time_namelookup_s":     round(f("time_namelookup"),    6),
            "time_connect_s":        round(f("time_connect"),       6),
            "time_appconnect_s":     round(f("time_appconnect"),    6),
            "time_pretransfer_s":    round(time_pretransfer,        6),
            "time_starttransfer_s":  round(f("time_starttransfer"), 6),
            "time_total_s":          round(time_total,              6),
            "time_to_last_byte_s":   round(time_total,              6),
            "body_transfer_s":       round(time_total - time_pretransfer, 6),
            "speed_Bps":             round(speed_bps),
            "speed_KBps":            round(speed_bps / 1024,       3),
            "speed_MBps":            round(speed_bps / 1048576,    3),
            "num_connects":          i("num_connects"),
            "num_redirects":         i("num_redirects"),
        })

# JSON
with open(json_file, "w") as fh:
    json.dump(records, fh, indent=2)

# CSV
with open(csv_file, "w", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
    writer.writeheader()
    writer.writerows(records)

# Summary: min/avg/max/p95 of time_total_s grouped by (protocol, payload)
groups = {}
for r in records:
    if r["http_code"] == 200:
        groups.setdefault((r["protocol"], r["payload"]), []).append(r["time_total_s"])

lines = [
    f"{'Protocol':<10} {'Payload':<20} {'N':>4}  {'Min':>8}  {'Avg':>8}  {'Max':>8}  {'P95':>8}",
    "-" * 72,
]
for proto in sorted({k[0] for k in groups}):
    for payload in PAYLOAD_ORDER:
        times = groups.get((proto, payload))
        if not times:
            lines.append(f"{proto:<10} {payload:<20} {'0':>4}  {'N/A':>8}  {'N/A':>8}  {'N/A':>8}  {'N/A':>8}")
            continue
        ts  = sorted(times)
        p95 = ts[max(0, int(0.95 * len(ts)) - 1)]
        lines.append(
            f"{proto:<10} {payload:<20} {len(ts):>4}"
            f"  {min(ts):>8.4f}  {statistics.mean(ts):>8.4f}"
            f"  {max(ts):>8.4f}  {p95:>8.4f}"
        )

with open(summary_file, "w") as fh:
    fh.write("\n".join(lines) + "\n")

print(f"JSON    : {json_file}")
print(f"CSV     : {csv_file}")
print(f"Summary : {summary_file}")
PYEOF

python3 "$PY_SCRIPT" "$TSV_FILE" "$JSON_FILE" "$CSV_FILE" "$SUMMARY_FILE"
rm -f "$PY_SCRIPT" "$TSV_FILE"

# ── symlinks → latest ──────────────────────────────────────────────────────
ln -sf "$(basename "$JSON_FILE")"    "${RESULTS_DIR}/load_results_latest.json"
ln -sf "$(basename "$CSV_FILE")"     "${RESULTS_DIR}/load_results_latest.csv"
ln -sf "$(basename "$SUMMARY_FILE")" "${RESULTS_DIR}/load_summary_latest.txt"

echo ""
echo "=== Summary ==="
cat "$SUMMARY_FILE"
echo ""
echo "JSON    : ${JSON_FILE}"
echo "CSV     : ${CSV_FILE}"
echo "Latest  : ${RESULTS_DIR}/load_results_latest.json"
echo "          ${RESULTS_DIR}/load_results_latest.csv"
