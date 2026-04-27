FROM ubuntu:20.04 AS build-lsquic

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y apt-utils build-essential git software-properties-common \
                       zlib1g-dev libevent-dev wget

# Install CMake 3.22 or higher (required by BoringSSL)
RUN wget https://github.com/Kitware/CMake/releases/download/v3.22.0/cmake-3.22.0-linux-x86_64.sh && \
    echo "b23922a3416bb21b31735ec0179b72b3f219e94c78748ff0c163640a5881bdf3  cmake-3.22.0-linux-x86_64.sh" | sha256sum -c && \
    chmod +x cmake-3.22.0-linux-x86_64.sh && \
    ./cmake-3.22.0-linux-x86_64.sh --skip-license --prefix=/usr/local && \
    rm cmake-3.22.0-linux-x86_64.sh

RUN add-apt-repository ppa:longsleep/golang-backports && \
    apt-get update && \
    apt-get install -y golang-1.21-go && \
    cp /usr/lib/go-1.21/bin/go* /usr/bin/.

ENV GOROOT /usr/lib/go-1.21

#copy certs, data files
RUN mkdir /src
WORKDIR /src
COPY ./certs /src/certs
COPY ./dummy_files /src/dummy_files

#make lsquic and copy certs
RUN git clone --depth=1 https://github.com/google/boringssl.git
RUN cd boringssl && \
    cmake . && \
    make

WORKDIR /src

RUN git clone https://github.com/litespeedtech/lsquic.git
RUN cd /src/lsquic && \
    git submodule update --init && \
    cmake -DLIBSSL_DIR=/src/boringssl . && \
    make

RUN cd lsquic && cp bin/http_client /usr/bin/ && cp bin/http_server /usr/bin

#make quicly
WORKDIR /src

RUN apt install libssl-dev -y

# RUN wget https://www.openssl.org/source/openssl-4.0.0.tar.gz && \
#     tar -xf /src/openssl-4.0.0.tar.gz

# ENV PKG_CONFIG_PATH /src/to/openssl/lib/pkgconfig cmake .
    
RUN git clone https://github.com/h2o/quicly.git && \
    cd quicly && \
    git submodule update --init --recursive && \
    cmake . && \
    make

RUN cd quicly && cp cli /usr/bin

ENV PORT 12345
ENV HOST 0.0.0.0

#todo: make msquic


ENTRYPOINT ["http_server","-c", "localhost,./certs/cert.pem,./certs/key.pem", "-r", "/src/dummy_files"]