FROM rust:slim AS traverse

WORKDIR /usr/src/traverse
COPY Cargo.toml Cargo.lock ./
COPY tokio-uring/Cargo.toml tokio-uring/Cargo.lock ./tokio-uring/
COPY tokio-uring/src ./tokio-uring/src
COPY io-uring/Cargo.toml io-uring/Cargo.lock ./io-uring/
COPY io-uring/src ./io-uring/src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
  cargo fetch

COPY src ./src

# without io-uring
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/traverse/target \
  cargo build -r
RUN --mount=type=cache,target=/usr/src/traverse/target \
  mv target/release/traverse /usr/local/bin/traverse

# with io-uring
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/traverse/target \
  cargo build -F io-uring -r
RUN --mount=type=cache,target=/usr/src/traverse/target \
  mv target/release/traverse /usr/local/bin/traverse-iouring


FROM debian:bullseye-slim AS tini

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    && rm -rf /var/lib/apt/lists/*

ADD tini /src
WORKDIR /src

RUN cmake .
RUN make


FROM debian:bullseye-slim AS linux-src

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/src/linux
RUN sh -c "wget -qO - https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz | tar -xJf - -C /usr/local/src/linux"


FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    hyperfine \
    && rm -rf /var/lib/apt/lists/*


COPY --chown=root:root init /sbin/init
COPY --from=tini /src/tini /bin/tini

COPY --from=linux-src /usr/local/src/linux /usr/local/src/linux

COPY --from=traverse /usr/local/bin/traverse /usr/local/bin/traverse-iouring /usr/local/bin/
