# ── Stage 1: build BoringSSL + lsquic ────────────────────────────────────────
# All source is COPIED from the host; no git clones happen inside the build.
# Run scripts/prepare-build.sh once before the first `docker compose build`.
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# golang-go: required by BoringSSL's cmake build system for code generation.
# perl: required by lsquic's cmake to generate source files.
RUN apt-get update && apt-get install -y \
        build-essential cmake golang-go perl \
        zlib1g-dev libevent-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# BoringSSL source (cloned on host by scripts/prepare-build.sh)
COPY boringssl/ ./boringssl/

RUN cd boringssl \
    && cmake -DCMAKE_BUILD_TYPE=Release . \
    && make -j"$(nproc)"

# lsquic source — submodules (lshpack, ls-qpack) must be initialized on the
# host via `git submodule update --init` before building.
COPY . ./lsquic/

RUN cd lsquic \
    && cmake -DLIBSSL_DIR=/src/boringssl . \
    && make -j"$(nproc)"

# ── Stage 2: shared runtime base ─────────────────────────────────────────────
FROM ubuntu:22.04 AS runtime-base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
        libevent-dev openssl jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/lsquic/bin/http_server /usr/local/bin/http_server
COPY --from=builder /src/lsquic/bin/http_client /usr/local/bin/http_client

# ── Stage 3a: server image ────────────────────────────────────────────────────
FROM runtime-base AS server-image

COPY docker/server-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4433/udp

ENTRYPOINT ["/entrypoint.sh"]

# ── Stage 3b: client validation image ────────────────────────────────────────
FROM runtime-base AS client-image

COPY docker/client-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# ── Stage 3c: QUIC load-tester image ─────────────────────────────────────────
FROM runtime-base AS load-tester-image

COPY docker/load-tester/run_tests.sh /run_tests.sh
RUN chmod +x /run_tests.sh

CMD ["/run_tests.sh"]
