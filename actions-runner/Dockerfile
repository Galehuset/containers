# GitHub Actions runner with a build toolchain.
#
# The stock ghcr.io/actions/actions-runner image has no compiler, so jobs
# that build anything native fail outright (Rust: "linker `cc` not found").
# GitHub's hosted runners ship a large toolset; this adds the common core:
# a C/C++ toolchain, pkg-config, OpenSSL, and the Linux audio/input/
# windowing headers Bevy and similar crates link against.
#
# Used by the self-hosted runner scale sets in Galehuset/k8s (github-even).
# For anything more specific, jobs should use their own `container:` image.
ARG VERSION=2.338.0

FROM ghcr.io/actions/actions-runner:${VERSION}

ARG VERSION
USER root
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential clang cmake pkg-config \
        git curl ca-certificates unzip zip jq xz-utils \
        libssl-dev \
        libasound2-dev libudev-dev \
        libx11-dev libxcursor-dev libxi-dev libxrandr-dev \
        libwayland-dev libxkbcommon-dev && \
    rm -rf /var/lib/apt/lists/*
USER runner

LABEL org.opencontainers.image.title="GitHub Actions runner ${VERSION} with build toolchain" \
      org.opencontainers.image.description="ghcr.io/actions/actions-runner:${VERSION} plus build-essential, clang, cmake, pkg-config, OpenSSL and common Linux audio/input/windowing dev libraries." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.url="https://github.com/Galehuset/containers/tree/main/actions-runner" \
      org.opencontainers.image.source="https://github.com/Galehuset/containers"
