FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# apt curl on Ubuntu 24.04 supports HTTP/1.1 and HTTP/2 (via libnghttp2)
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        python3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY run_tests.sh /run_tests.sh
RUN chmod +x /run_tests.sh

ENTRYPOINT ["/run_tests.sh"]
