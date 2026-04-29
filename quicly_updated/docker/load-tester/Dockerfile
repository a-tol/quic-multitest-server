# ── Stage 1: build curl with HTTP/1.1 + HTTP/2 + HTTP/3 ───────────────────
FROM ubuntu:24.04 AS curl-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bzip2 \
        ca-certificates \
        g++ \
        gcc \
        git \
        libtool \
        make \
        pkg-config \
        wget \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ── quictls: OpenSSL fork with QUIC transport APIs ────────────────────────
RUN git clone --depth 1 --branch openssl-3.0.10+quic \
        https://github.com/quictls/openssl /opt/src/quictls \
    && cd /opt/src/quictls \
    && ./config enable-tls1_3 no-shared --prefix=/usr/local/quictls \
    && make install clean

# Detect whether quictls installed to lib or lib64 and save the path.
# All subsequent steps read /tmp/quictls_env to get consistent values.
RUN LIBDIR=$(find /usr/local/quictls -maxdepth 1 -name "lib*" -type d \
              | grep -v pkgconfig | sort | tail -1) \
    && echo "QUICTLS_LIBDIR=${LIBDIR}"                          > /tmp/quictls_env \
    && echo "QUICTLS_INCDIR=/usr/local/quictls/include"        >> /tmp/quictls_env \
    && echo "QUICTLS_PKGDIR=${LIBDIR}/pkgconfig"               >> /tmp/quictls_env \
    && cat /tmp/quictls_env \
    && test -f "${LIBDIR}/pkgconfig/openssl.pc" \
    || { echo "FATAL: openssl.pc not found under ${LIBDIR}"; exit 1; }

# ── nghttp2: HTTP/2 framing (static) ─────────────────────────────────────
RUN git clone --depth 1 --branch v1.59.0 \
        https://github.com/nghttp2/nghttp2 /opt/src/nghttp2 \
    && cd /opt/src/nghttp2 \
    && autoreconf -fi \
    && ./configure --enable-lib-only --disable-shared \
    && make install clean

# ── nghttp3: HTTP/3 framing (static) ─────────────────────────────────────
RUN . /tmp/quictls_env \
    && git clone --depth 1 --branch v1.1.0 \
        https://github.com/ngtcp2/nghttp3 /opt/src/nghttp3 \
    && cd /opt/src/nghttp3 \
    && autoreconf -fi \
    && PKG_CONFIG_PATH="${QUICTLS_PKGDIR}" \
       CFLAGS="-I${QUICTLS_INCDIR}" \
       LDFLAGS="-L${QUICTLS_LIBDIR}" \
       ./configure --enable-lib-only --disable-shared \
    && make install clean

# ── ngtcp2: QUIC transport + quictls crypto backend (static) ─────────────
# CFLAGS and LDFLAGS are mandatory: without them ngtcp2 configure cannot
# compile the quictls feature probe, skips the backend, and never installs
# ngtcp2_crypto_quictls.h — which then breaks curl's compilation.
RUN . /tmp/quictls_env \
    && git clone --depth 1 --branch v1.2.0 \
        https://github.com/ngtcp2/ngtcp2 /opt/src/ngtcp2 \
    && cd /opt/src/ngtcp2 \
    && autoreconf -fi \
    && PKG_CONFIG_PATH="${QUICTLS_PKGDIR}" \
       CFLAGS="-I${QUICTLS_INCDIR}" \
       LDFLAGS="-L${QUICTLS_LIBDIR}" \
       ./configure --enable-lib-only --disable-shared \
    && make install clean \
    && test -f /usr/local/include/ngtcp2/ngtcp2_crypto_quictls.h \
    || { echo "FATAL: ngtcp2_crypto_quictls.h missing — quictls backend not built"; exit 1; }

# ── curl 8.6.0: HTTP/1.1 + HTTP/2 + HTTP/3 ──────────────────────────────
RUN . /tmp/quictls_env \
    && wget --quiet -O - https://curl.se/download/curl-8.6.0.tar.bz2 \
       | tar xjf - -C /opt/src \
    && cd /opt/src/curl-8.6.0 \
    && PKG_CONFIG_PATH="${QUICTLS_PKGDIR}:/usr/local/lib/pkgconfig" \
       ./configure \
           --disable-shared \
           --without-libpsl \
           --with-nghttp2 \
           --with-ngtcp2 \
           --with-nghttp3 \
           --with-openssl=/usr/local/quictls \
    && make install clean

# Hard fail at build time if HTTP/3 is not in the binary.
RUN /usr/local/bin/curl --version | tee /dev/stderr | grep -i "HTTP3" \
    || { echo "FATAL: curl built without HTTP/3"; exit 1; }

# ── Stage 2: lean runtime ─────────────────────────────────────────────────
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        ca-certificates \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=curl-builder /usr/local/bin/curl /usr/local/bin/curl

COPY run_tests.sh /run_tests.sh
RUN chmod +x /run_tests.sh

ENTRYPOINT ["/run_tests.sh"]
