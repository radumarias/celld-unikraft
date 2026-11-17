# syntax=docker/dockerfile:1.7
#
# celld as a Unikraft unikernel. Build the initrd that `kraft run` boots:
#
#   docker build --platform linux/amd64 -f unikraft/Dockerfile --target initrd \
#     --output type=local,dest=unikraft/.build .
#
# and the image that runs `celld deploy` beside it (`--target deployer`).
# unikraft/run-local.sh runs both. Unikraft's ELF loader (unikraft.org/base)
# is x86_64, so build for linux/amd64.

ARG RUST_VERSION=1.98.1
ARG ESBUILD_VERSION=0.25.12
# `build` cross-compiles. `build-emulated` compiles inside the target
# platform instead: slow under emulation, but it needs no cross toolchain.
ARG CELLD_BUILD=build

# Compile on the build machine's own architecture and cross-compile to the
# target. An emulated amd64 compile of V8-linked celld on Apple silicon takes
# hours; a cross compile takes as long as a native one.
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-bookworm AS build
ARG TARGETARCH
ARG BUILDARCH
# `lab` skips the fat-LTO relink of `release`. Pass `release` for a smaller,
# slower-to-build binary.
ARG CELLD_PROFILE=lab
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu; package=x86-64-linux-gnu; prefix=x86_64-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu; package=aarch64-linux-gnu; prefix=aarch64-linux-gnu ;; \
      *) echo "unsupported target $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    printf '%s %s\n' "$triple" "$prefix" > /target; \
    rustup target add "$triple"; \
    if [ "$TARGETARCH" != "$BUILDARCH" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        "gcc-$package" "g++-$package" "binutils-$package" "libc6-dev-$TARGETARCH-cross"; \
      rm -rf /var/lib/apt/lists/*; \
    fi
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN --mount=type=cache,id=celld-unikraft-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=celld-unikraft-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=celld-unikraft-target-${TARGETARCH},target=/src/target,sharing=locked \
    set -eux; \
    read -r triple prefix < /target; \
    strip=strip; \
    if [ "$TARGETARCH" != "$BUILDARCH" ]; then \
      upper=$(printf '%s' "$triple" | tr 'a-z-' 'A-Z_'); \
      lower=$(printf '%s' "$triple" | tr '-' '_'); \
      export "CARGO_TARGET_${upper}_LINKER=${prefix}-gcc" \
             "CC_${lower}=${prefix}-gcc" "CXX_${lower}=${prefix}-g++" "AR_${lower}=${prefix}-ar"; \
      strip="${prefix}-strip"; \
    fi; \
    cargo build --profile "$CELLD_PROFILE" --locked -p celld --target "$triple"; \
    mkdir -p /out; \
    install -m 755 "target/$triple/$CELLD_PROFILE/celld" /out/celld; \
    "$strip" /out/celld

FROM rust:${RUST_VERSION}-bookworm AS build-emulated
ARG CELLD_PROFILE=lab
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN --mount=type=cache,id=celld-unikraft-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=celld-unikraft-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=celld-unikraft-emulated-target,target=/src/target,sharing=locked \
    cargo build --profile "$CELLD_PROFILE" --locked -p celld && \
    mkdir -p /out && \
    install -m 755 "target/$CELLD_PROFILE/celld" /out/celld && \
    strip /out/celld

FROM ${CELLD_BUILD} AS celld-binary

# The file system the unikernel boots: Debian's glibc and CA certificates, and
# celld. Unikraft runs the binary unchanged on its Linux-compatible ELF loader.
FROM debian:bookworm-slim AS rootfs
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man /usr/share/locale
COPY LICENSE NOTICE /usr/share/doc/celld/
COPY --from=celld-binary /out/celld /usr/local/bin/celld
RUN mkdir -p /var/lib/celld/state /tmp && chmod 1777 /tmp

# Pack it into the cpio initrd the Kraftfile names.
FROM debian:bookworm-slim AS pack
RUN apt-get update && \
    apt-get install -y --no-install-recommends cpio && \
    rm -rf /var/lib/apt/lists/*
COPY --from=rootfs / /rootfs/
RUN mkdir -p /rootfs/proc /rootfs/sys /rootfs/dev && \
    cd /rootfs && find . -mindepth 1 | cpio --quiet -o -H newc > /rootfs.cpio

FROM scratch AS initrd
COPY --from=pack /rootfs.cpio /rootfs.cpio

# `celld deploy` writes the application into the bucket from a container, so
# the host needs neither celld nor esbuild.
FROM rootfs AS deployer
ARG ESBUILD_VERSION
ARG TARGETARCH
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    case "$TARGETARCH" in amd64) npm_arch=x64 ;; arm64) npm_arch=arm64 ;; esac; \
    curl -fsSL "https://registry.npmjs.org/@esbuild/linux-${npm_arch}/-/linux-${npm_arch}-${ESBUILD_VERSION}.tgz" \
      | tar -xz -C /tmp; \
    install -m 755 /tmp/package/bin/esbuild /usr/local/bin/esbuild; \
    rm -rf /tmp/package /var/lib/apt/lists/*
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/celld"]

# A local S3 for `run-local.sh`: moto's server passes celld's conditional-write
# check (`celld diagnose`). It keeps objects in memory, so the bucket lives as
# long as this container does. MinIO no longer publishes public images.
FROM python:3.12-slim AS s3
ARG MOTO_VERSION=5.2.5
RUN pip install --no-cache-dir "moto[server]==${MOTO_VERSION}"
EXPOSE 9000
ENTRYPOINT ["moto_server", "-H", "0.0.0.0", "-p", "9000"]
