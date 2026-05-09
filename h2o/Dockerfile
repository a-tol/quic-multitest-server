# Stage 1: Build h2o from source
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    gcc \
    g++ \
    make \
    git \
    libssl-dev \
    libuv1-dev \
    libev-dev \
    zlib1g-dev \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY ./ /src/lsquic
WORKDIR /src/lsquic



RUN 	find / &&\
	cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_MRUBY=OFF \
        -DWITH_FUSION=OFF \
        -DWITH_DTRACE=OFF \
    && cmake --build build --target h2o -j"$(nproc)" \
    && strip build/h2o

# Stage 2: Minimal runtime image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libuv1t64 \
    libev4t64 \
    zlib1g \
    openssl \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/lsquic/build/h2o /usr/local/bin/h2o
COPY ./docker/server/h2o.conf /etc/h2o/h2o.conf
COPY ./docker/server/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080 8443

HEALTHCHECK --interval=5s --timeout=10s --retries=12 --start-period=10s \
    CMD curl -sf http://localhost:8080/1mb.bin -o /dev/null

ENTRYPOINT ["/entrypoint.sh"]
