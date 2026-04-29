# Stage 1: Build msquic and quicsample
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential \
    cmake \
    clang \
    git \
    perl \
    nasm \
    libssl-dev \
    libnuma-dev \
    liburing-dev \
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

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
    openssl \
    libnuma1 \
    liburing2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bin/Release/quicsample /usr/local/bin/quicsample
COPY --from=builder /build/bin/Release/libmsquic.so* /usr/local/lib/
RUN ldconfig

COPY docker/server-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# quicsample server listens on UDP 4567 by default
EXPOSE 4567/udp

ENTRYPOINT ["/entrypoint.sh"]

# Stage 3: Client runtime
FROM ubuntu:24.04 AS client

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
    libnuma1 \
    liburing2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bin/Release/quicsample /usr/local/bin/quicsample
COPY --from=builder /build/bin/Release/libmsquic.so* /usr/local/lib/
RUN ldconfig

COPY docker/client-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
