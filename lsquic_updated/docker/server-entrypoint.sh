#!/bin/bash
set -e

CERT_DIR=/certs
mkdir -p "$CERT_DIR"

# Generate self-signed TLS certificate (SAN covers both the service name and localhost)
openssl req -x509 -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out    "$CERT_DIR/server.crt" \
    -days 365 -nodes \
    -subj "/CN=server" \
    -addext "subjectAltName=DNS:server,DNS:localhost,IP:127.0.0.1"

echo "Certificate generated."
echo "Starting lsquic HTTP/3 server on UDP port 4433 ..."
echo "Document root: /payloads"

# -s  listen address
# -c  SNI-hostname,cert,key
#     Register for both "server" (Docker-internal http_client) and
#     "localhost" (Chrome connecting from the Mac host via port mapping)
# -r  document root
exec http_server \
    -s 0.0.0.0:4433 \
    -c server,"$CERT_DIR/server.crt","$CERT_DIR/server.key" \
    -c localhost,"$CERT_DIR/server.crt","$CERT_DIR/server.key" \
    -r /payloads
