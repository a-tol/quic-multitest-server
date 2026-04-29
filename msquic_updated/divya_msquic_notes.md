# msquic — Complete Implementation Notes
**Author:** Divya Medicherla  
**Date:** April 2026  
**Repo:** https://github.com/microsoft/msquic

---

## 1. Project Overview

This project sets up a local QUIC and HTTP/3 testing environment using Microsoft's
**msquic** library. The goal is to:

- Run a custom QUIC server and client using the `quicsample` application
- Serve static payload files over HTTP/3 (QUIC/UDP) and HTTP/2+HTTP/1.1 (TCP)
- Measure and compare timing metrics between QUIC and TCP protocols
- Capture all results in structured CSV and JSON files

The test methodology mirrors the research paper being studied, which benchmarks
QUIC vs TCP performance across payloads of varying sizes.

---

## 2. Repository Structure

```
msquic/
├── src/
│   ├── core/                  ← QUIC protocol implementation
│   │   ├── connection.c/h     ← connection state machine
│   │   ├── stream.c/h         ← stream multiplexing
│   │   ├── cubic.c/h          ← CUBIC congestion control (default)
│   │   ├── bbr.c/h            ← BBR congestion control (preview)
│   │   ├── loss_detection.c/h ← PTO-based loss detection
│   │   ├── crypto.c/h         ← TLS/handshake integration
│   │   ├── send.c/h           ← packet coalescing + pacing
│   │   └── timer_wheel.c/h    ← slot-based timer management
│   └── tools/
│       └── sample/
│           └── sample.c       ← quicsample client/server app
├── submodules/
│   ├── quictls/               ← TLS library (OpenSSL fork for QUIC)
│   └── clog/                  ← logging framework
├── docker/
│   ├── Dockerfile             ← multi-stage: builder → server + client
│   ├── server-entrypoint.sh   ← TLS cert generation + server startup
│   ├── client-entrypoint.sh   ← connection retry + output validation
│   ├── h3-server/
│   │   ├── Dockerfile         ← Caddy + openssl
│   │   ├── Caddyfile          ← HTTP/3 file server config
│   │   └── entrypoint.sh      ← cert generation + caddy start
│   └── load-tester/
│       ├── Dockerfile         ← Alpine curl with HTTP/3 support
│       └── run_tests.sh       ← 40x per payload, CSV+JSON output
├── scripts/
│   └── generate-payloads.sh   ← creates 6 binary payload files
├── payloads/                  ← generated test files (not committed)
├── results/                   ← all test output files (not committed)
└── docker-compose.yml         ← 5-service orchestration
```

---

## 3. QUIC Implementation Methodologies (msquic Core)

### 3.1 Congestion Control
- **Default algorithm:** CUBIC (RFC 8312bis)
  - Initial window: 10 packets
  - Multiplicative decrease factor β = 0.7
  - Cubic scaling constant C = 0.4
  - Growth formula: `W_cubic(t) = C × (t − K)³ + W_max`
- **Preview algorithm:** BBR
  - 4 states: STARTUP → DRAIN → PROBE_BW → PROBE_RTT
  - Pacing gain cycles: [1.25, 0.75, 1, 1, 1, 1, 1, 1]
  - Does not react to packet loss; uses BtlBw + RTprop estimates

### 3.2 Loss Detection
- Outstanding packets tracked in a `SentPackets` linked list
- Loss detected via ACK gap ranges or **Probe Timeout (PTO)** timer
- Lost packets moved to `LostPackets` list and retransmitted
- Multiple encryption levels tracked independently during handshake

### 3.3 Flow Control
- Two-level hierarchical windows:
  - **Connection level:** `MAX_DATA` frame limits total bytes across all streams
  - **Stream level:** `MAX_STREAM_DATA` limits bytes per stream
- Accumulator-based: new window advertisements sent when enough bytes consumed

### 3.4 Execution Model
- Worker threads affinitized to CPU partitions
- All processing for a connection stays on one thread (no locking needed)
- Connections assigned to least-loaded worker by `AverageQueueDelay`
- Async operation queue drives all I/O events

### 3.5 Packet Sending
- Multiple QUIC packets coalesced into one UDP datagram
- Header protection computed in batches (AES)
- Sending is pacing-gated by congestion controller's `SendAllowance`

---

## 4. Setup Steps

### Step 1 — Prerequisites
```bash
docker --version        # Docker Desktop must be running
docker compose version  # need v2+
git --version
```

### Step 2 — Clone Repository
```bash
git clone https://github.com/microsoft/msquic.git
cd msquic
```

### Step 3 — Initialize Submodules
```bash
git submodule update --init submodules/quictls submodules/clog
```
> Takes 1–2 minutes. `quictls` is the TLS library compiled from source.

### Step 4 — Generate Payload Files
```bash
chmod +x scripts/generate-payloads.sh
./scripts/generate-payloads.sh
```

Payload files created in `./payloads/`:

| File | Size | Purpose |
|---|---|---|
| `100kb.bin` | 100 KB | Tests handshake overhead dominance |
| `1mb.bin` | 1 MB | Short-lived flow benchmark |
| `5mb.bin` | 5 MB | Steady-state congestion control |
| `small_page.bin` | 0.47 MB | Web-page small tier |
| `medium_page.bin` | 1.54 MB | Web-page medium tier |
| `large_page.bin` | 2.83 MB | Web-page large tier |

All files are filled with `/dev/urandom` (random, incompressible bytes) to
prevent any network-layer compression from skewing results.

### Step 5 — Create Results Directory
```bash
mkdir -p results
```

### Step 6 — Build All Docker Images
```bash
docker compose build
```
First build takes 8–15 minutes (compiles msquic + quictls from source).
Subsequent builds use Docker layer cache.

### Step 7 — Trust the HTTP/3 Server Certificate (one-time)
```bash
docker compose up h3-server &
sleep 5
docker cp quic-h3-server:/certs/server.crt ./caddy-root.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./caddy-root.crt
docker compose down
```

---

## 5. Docker Services

### docker-compose.yml
```yaml
services:
  server:           # quicsample custom QUIC server  (UDP 4567)
  client:           # quicsample client
  h3-server:        # Caddy HTTP/3 file server       (TCP+UDP 4433)
  load-tester:      # curl HTTP/3 only               → load_results_*.json
  load-tester-tcp:  # curl HTTP/1.1 + HTTP/2         → tcp_results_*.json
```

---

## 6. Code — All Configuration Files

### 6.1 docker/Dockerfile (quicsample build)
```dockerfile
# Stage 1: Build msquic and quicsample
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential cmake clang git perl nasm \
    libssl-dev libnuma-dev liburing-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN cmake -S . -B /build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DQUIC_BUILD_TOOLS=ON \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_BUILD_PERF=OFF \
    -DQUIC_ENABLE_LOGGING=OFF

RUN cmake --build /build --target quicsample -j$(nproc)

# Stage 2: Server runtime
FROM ubuntu:24.04 AS server
RUN apt-get update && apt-get install --no-install-recommends -y \
    openssl libnuma1 liburing2 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bin/Release/quicsample /usr/local/bin/quicsample
COPY --from=builder /build/bin/Release/libmsquic.so* /usr/local/lib/
RUN ldconfig

COPY docker/server-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 4567/udp
ENTRYPOINT ["/entrypoint.sh"]

# Stage 3: Client runtime
FROM ubuntu:24.04 AS client
RUN apt-get update && apt-get install --no-install-recommends -y \
    libnuma1 liburing2 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bin/Release/quicsample /usr/local/bin/quicsample
COPY --from=builder /build/bin/Release/libmsquic.so* /usr/local/lib/
RUN ldconfig

COPY docker/client-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

### 6.2 docker/server-entrypoint.sh
```bash
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
FIFO=/tmp/server_stdin
mkfifo "$FIFO"
exec 3>"$FIFO"

echo "Starting quicsample server on UDP port 4567..."
quicsample -server \
    -cert_file:"$CERT_DIR/server.cert" \
    -key_file:"$CERT_DIR/server.key" \
    < "$FIFO" 2>&1 | tee "$RESULTS_DIR/server.log"
```

**Key design:** `quicsample -server` blocks on `getchar()` waiting for Enter.
A named FIFO keeps the write end open (via bash fd 3) so `getchar()` never
returns EOF, keeping the server alive indefinitely inside Docker.

### 6.3 docker/client-entrypoint.sh
```bash
#!/bin/bash
set -e

TARGET="${TARGET:-server}"
RESULTS_DIR="/results"
MAX_RETRIES="${MAX_RETRIES:-15}"
RETRY_DELAY="${RETRY_DELAY:-2}"

mkdir -p "$RESULTS_DIR"

echo "Client will connect to $TARGET..."

for i in $(seq 1 "$MAX_RETRIES"); do
    echo "Attempt $i/$MAX_RETRIES: connecting to $TARGET..."
    OUTPUT=$(quicsample -client -unsecure -target:"$TARGET" 2>&1)
    echo "$OUTPUT" | tee -a "$RESULTS_DIR/client.log"

    if echo "$OUTPUT" | grep -q "\[conn\].*Connected"; then
        echo "=== Client connected and exchange completed successfully ==="
        exit 0
    fi
    echo "Connection not established yet, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done

echo "ERROR: Failed to connect after $MAX_RETRIES attempts."
exit 1
```

**Key design:** `quicsample` always returns exit code 0 even on failure. The
script checks for `[conn].*Connected` in the output text to confirm a real
connection, and retries if not found.

### 6.4 docker/h3-server/Dockerfile
```dockerfile
FROM caddy:2-alpine
RUN apk add --no-cache openssl
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

### 6.5 docker/h3-server/entrypoint.sh
```bash
#!/bin/sh
set -e

mkdir -p /certs

if [ ! -f /certs/server.crt ]; then
    echo "Generating TLS certificate for localhost..."
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout /certs/server.key \
        -out /certs/server.crt \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    echo "Certificate generated."
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
```

**Key design:** The SAN (Subject Alternative Name) must include `DNS:localhost`
because Chrome ignores the CN field since 2017 and validates only SAN entries.

### 6.6 docker/h3-server/Caddyfile
```
{
    log {
        output stdout
        format console
    }
}

:4433 {
    tls /certs/server.crt /certs/server.key
    root * /payloads
    file_server browse
}
```

**Key design:** Site address `:4433` (not `localhost:4433`) binds to all
interfaces (0.0.0.0:4433) so Docker's port-forwarding can reach it. Caddy
automatically enables HTTP/3 on every TLS listener — the same port serves
HTTP/1.1, HTTP/2 (TCP) and HTTP/3 (UDP/QUIC).

### 6.7 docker/load-tester/Dockerfile
```dockerfile
FROM alpine:latest
RUN apk add --no-cache curl bash bc
COPY run_tests.sh /run_tests.sh
RUN chmod +x /run_tests.sh
ENTRYPOINT ["/run_tests.sh"]
```

**Key design:** `alpine:latest` ships curl compiled with `ngtcp2` (HTTP/3
support). The `curlimages/curl` image does NOT include HTTP/3, which caused
HTTP/3 requests to silently fall back to HTTP/2.

Verify HTTP/3 support:
```bash
docker compose run --rm --entrypoint curl load-tester --version | grep Features
# Must show: HTTP3
```

### 6.8 docker/load-tester/run_tests.sh
```bash
#!/bin/bash
# TEST_MODE=quic  → HTTP/3 only          → load_results_*.csv/json
# TEST_MODE=tcp   → HTTP/1.1 + HTTP/2    → tcp_results_*.csv/json

set -e

SERVER="${SERVER_URL:-https://h3-server:4433}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
REPETITIONS="${REPETITIONS:-40}"
CACERT="${CACERT:-/certs/server.crt}"
TEST_MODE="${TEST_MODE:-quic}"

RUN_TS=$(date -u +"%Y%m%dT%H%M%SZ")

if [ "$TEST_MODE" = "tcp" ]; then
    PREFIX="tcp_results"
    PROTOCOLS=("--http1.1|HTTP/1.1" "--http2|HTTP/2")
else
    PREFIX="load_results"
    PROTOCOLS=("--http3-prior-knowledge|HTTP/3")
fi

PAYLOADS=("100kb.bin" "1mb.bin" "5mb.bin" "small_page.bin" "medium_page.bin" "large_page.bin")

# curl timing fields captured per request
CURL_FMT="size_download:%{size_download}\n
http_version:%{http_version}\n
http_code:%{http_code}\n
time_namelookup:%{time_namelookup}\n
time_connect:%{time_connect}\n
time_appconnect:%{time_appconnect}\n
time_pretransfer:%{time_pretransfer}\n
time_starttransfer:%{time_starttransfer}\n
time_total:%{time_total}\n
speed_download:%{speed_download}\n
num_connects:%{num_connects}\n
num_redirects:%{num_redirects}\n"
```

**Protocol switch:** Controlled by `TEST_MODE` environment variable.
- `TEST_MODE=quic` → uses `--http3-prior-knowledge` (QUIC, no Alt-Svc negotiation)
- `TEST_MODE=tcp`  → uses `--http1.1` and `--http2`

**Output files:**
- QUIC run: `load_results_<timestamp>.csv` + `.json`
- TCP run:  `tcp_results_<timestamp>.csv` + `.json`
- Both create `_latest` symlinks for easy scripting

### 6.9 scripts/generate-payloads.sh
```bash
#!/bin/bash
OUTDIR="${1:-./payloads}"
mkdir -p "$OUTDIR"

# Raw protocol benchmarks
dd if=/dev/urandom of="$OUTDIR/100kb.bin"       bs=1K  count=100   status=none
dd if=/dev/urandom of="$OUTDIR/1mb.bin"         bs=1M  count=1     status=none
dd if=/dev/urandom of="$OUTDIR/5mb.bin"         bs=1M  count=5     status=none

# Web-page tier benchmarks
dd if=/dev/urandom of="$OUTDIR/small_page.bin"  bs=1K  count=470   status=none
dd if=/dev/urandom of="$OUTDIR/medium_page.bin" bs=1K  count=1540  status=none
dd if=/dev/urandom of="$OUTDIR/large_page.bin"  bs=1K  count=2830  status=none
```

**Key design:** `/dev/urandom` produces incompressible data. Using zeros or
repetitive patterns would allow TCP/TLS compression to reduce the effective
payload size, making results smaller than real-world transfers.

---

## 7. Running the Tests

### 7.1 Run quicsample (custom QUIC protocol, UDP 4567)
```bash
# Terminal 1
docker compose up server

# Terminal 2
docker compose up client

docker compose down
```

Expected client output:
```
[conn][0x...] Connected
[strm][0x...] Sending data...
[strm][0x...] Data sent
[strm][0x...] Data received
[strm][0x...] All done
=== Client connected and exchange completed successfully ===
```

### 7.2 Run QUIC load test (HTTP/3, port 4433)
```bash
# Terminal 1
docker compose up h3-server

# Terminal 2
docker compose run --rm load-tester
```

### 7.3 Run TCP load test (HTTP/1.1 + HTTP/2, port 4433)
```bash
# Terminal 2 (h3-server still running)
docker compose run --rm load-tester-tcp
```

### 7.4 View results
```bash
cat results/load_summary_latest.txt    # QUIC summary
cat results/tcp_summary_latest.txt     # TCP summary
cat results/load_results_latest.json   # QUIC full data
cat results/tcp_results_latest.json    # TCP full data
```

---

## 8. JSON Output Format

Each request produces one record:

```json
{
  "run_id":               "20260426T222329Z",
  "timestamp":            "2026-04-26T22:23:29Z",
  "protocol":             "HTTP/3",
  "http_version":         "3",
  "payload":              "1mb.bin",
  "attempt":              1,
  "http_code":            200,
  "size_bytes":           1048576,
  "time_namelookup_s":    0.000197,
  "time_connect_s":       0.000245,
  "time_appconnect_s":    0.002844,
  "time_pretransfer_s":   0.002883,
  "time_starttransfer_s": 0.003337,
  "time_total_s":         0.021300,
  "time_to_last_byte_s":  0.021300,
  "body_transfer_s":      0.018000,
  "speed_Bps":            49229500,
  "speed_KBps":           48075.000,
  "speed_MBps":           46.948,
  "num_connects":         1,
  "num_redirects":        0
}
```

### Field meanings

| Field | Meaning |
|---|---|
| `time_namelookup_s` | DNS resolution time |
| `time_connect_s` | TCP handshake complete |
| `time_appconnect_s` | TLS / QUIC handshake complete |
| `time_pretransfer_s` | Protocol headers sent, ready to transfer |
| `time_starttransfer_s` | **Time To First Byte (TTFB)** |
| `time_total_s` | Full transfer complete |
| `time_to_last_byte_s` | **Time To Last Byte (TTLB)** — same as `time_total_s` |
| `body_transfer_s` | Pure data transfer = `time_total_s − time_starttransfer_s` |
| `speed_MBps` | Average download throughput |
| `http_version` | Actual protocol negotiated: `1.1`, `2`, or `3` |

---

## 9. Result Files in results/

```
results/
├── load_results_<timestamp>.csv      ← QUIC run, all 240 rows (6×40)
├── load_results_<timestamp>.json     ← same, JSON format
├── load_results_latest.csv           ← symlink → most recent QUIC CSV
├── load_results_latest.json          ← symlink → most recent QUIC JSON
├── load_summary_<timestamp>.txt      ← QUIC min/avg/max/p95 table
├── load_summary_latest.txt           ← symlink → most recent QUIC summary
├── tcp_results_<timestamp>.csv       ← TCP run, all 480 rows (6×2×40)
├── tcp_results_<timestamp>.json      ← same, JSON format
├── tcp_results_latest.csv            ← symlink → most recent TCP CSV
├── tcp_results_latest.json           ← symlink → most recent TCP JSON
├── tcp_summary_<timestamp>.txt       ← TCP min/avg/max/p95 table
├── tcp_summary_latest.txt            ← symlink → most recent TCP summary
└── client.log                        ← quicsample raw connection log
```

Summary tables report four metrics per payload per protocol:
- **Total Transfer Time** — end-to-end latency
- **Time To First Byte (TTFB)** — connection + protocol setup cost
- **TLS Handshake Time** — just the crypto negotiation
- **Download Speed (MB/s)** — throughput

Each metric shows: **Min / Avg / Max / P95 / Sample count**

---

## 10. Key Observations

### 10.1 quicsample protocol
- Uses a custom ALPN identifier `"sample"` — not HTTP
- Client opens one bidirectional stream, sends 100 bytes, closes send direction
- Server echoes 100 bytes back after client closes
- Connection shuts down after 1-second idle timeout
- The `getchar()` call in server code requires a FIFO workaround in Docker
  to prevent immediate EOF and premature server shutdown

### 10.2 HTTP/3 image selection
- `curlimages/curl:latest` — does **NOT** include HTTP/3 (missing `ngtcp2`)
- `alpine:latest` curl — **includes** HTTP/3 via `ngtcp2`
- Without HTTP/3 support, `--http3-prior-knowledge` silently falls back to
  HTTP/2 and `http_version` shows `2` instead of `3`
- Always verify: `curl --version | grep Features` must show `HTTP3`

### 10.3 Certificate (SAN vs CN)
- Chrome stopped accepting `CN=localhost` for TLS validation in 2017
- SAN field `subjectAltName=DNS:localhost,IP:127.0.0.1` is mandatory
- Caddy's `:4433` site address (not `localhost:4433`) binds to 0.0.0.0
  so Docker port-forwarding can reach the container

### 10.4 Docker image caching
- Any change to `run_tests.sh` requires `docker compose build --no-cache load-tester`
- Without `--no-cache`, Docker uses a cached layer and the old script runs
- The symptom: new fields or logic changes silently not appearing in output

### 10.5 Protocol separation
- QUIC mode: HTTP/3 only (`--http3-prior-knowledge`)
- TCP mode: HTTP/1.1 + HTTP/2 (`--http1.1`, `--http2`)
- Controlled via `TEST_MODE` environment variable
- Previously both modes included HTTP/2, which split QUIC results 50/50
  between HTTP/2 and HTTP/3

### 10.6 Congestion control
- All tests run CUBIC by default
- BBR available as a preview feature (requires `QUIC_API_ENABLE_PREVIEW_FEATURES`)
- CUBIC β = 0.7 means 30% window reduction on each loss event
- HyStart++ (hybrid slow-start) is present but disabled by default

---

## 11. Chrome HTTP/3 Testing

```bash
# Trust the server cert (one-time)
docker cp quic-h3-server:/certs/server.crt ./caddy-root.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./caddy-root.crt

# Kill existing Chrome instance
pkill -x "Google Chrome"

# Launch with QUIC forced
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --enable-quic \
  --origin-to-force-quic-on=localhost:4433 \
  --user-data-dir=/tmp/chrome-quic-test
```

Navigate to `https://localhost:4433` and download payloads.

Verify HTTP/3: `F12` → Network → right-click column headers → enable Protocol → should show `h3`.

---

## 12. Changing Protocol Mode in Code

**To add/change protocols** — edit [docker/load-tester/run_tests.sh](docker/load-tester/run_tests.sh):

```bash
if [ "$TEST_MODE" = "tcp" ]; then
    PROTOCOLS=(
        "--http1.1|HTTP/1.1"      # ← edit TCP protocols here
        "--http2|HTTP/2"
    )
else
    PROTOCOLS=(
        "--http3-prior-knowledge|HTTP/3"   # ← edit QUIC protocols here
    )
fi
```

Each entry format: `"<curl-flag>|<label>"`

**To change repetitions** — edit [docker-compose.yml](docker-compose.yml):
```yaml
load-tester:
  environment:
    - REPETITIONS=40    # ← change here
```

Or override at runtime without editing:
```bash
docker compose run --rm -e REPETITIONS=80 load-tester
```

**After any script change — always rebuild:**
```bash
docker compose build --no-cache load-tester
```

---

## 13. Quick Reference Commands

```bash
# Full setup (first time)
git submodule update --init submodules/quictls submodules/clog
./scripts/generate-payloads.sh
mkdir -p results
docker compose build

# Start HTTP/3 server
docker compose up h3-server

# Run QUIC test (HTTP/3 only)
docker compose run --rm load-tester

# Run TCP test (HTTP/1.1 + HTTP/2)
docker compose run --rm load-tester-tcp

# View results
cat results/load_summary_latest.txt
cat results/tcp_summary_latest.txt

# Stop everything
docker compose down

# Rebuild after script changes
docker compose build --no-cache load-tester
```
