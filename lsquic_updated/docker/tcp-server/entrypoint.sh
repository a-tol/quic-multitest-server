#!/bin/sh
set -e

CERT_DIR=/certs
mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out    "$CERT_DIR/server.crt" \
    -days 365 -nodes \
    -subj "/CN=tcp-server" \
    -addext "subjectAltName=DNS:tcp-server,DNS:localhost,IP:127.0.0.1" \
    2>/dev/null

echo "Certificate generated."
echo "Starting nginx (HTTP/1.1 + HTTP/2) on TCP port 8080 ..."

exec nginx -g "daemon off;"
