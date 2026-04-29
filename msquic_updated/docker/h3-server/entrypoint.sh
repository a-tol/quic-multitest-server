#!/bin/sh
set -e

mkdir -p /certs

# Generate self-signed cert with SAN covering both localhost and 127.0.0.1
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
