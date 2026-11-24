# GitHub Actions runner with a build toolchain.
#
# The stock ghcr.io/actions/actions-runner image has no compiler, so jobs
# that build anything native fail outright (Rust: "linker `cc` not found").
# GitHub's hosted runners ship a large toolset; this adds the common core:
# a C/C++ toolchain, pkg-config, OpenSSL, and the Linux audio/input/
# windowing headers Bevy and similar crates link against. Plus faster
# linkers (mold, lld) and sccache, for Rust's compile/link-heavy builds.
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
        libwayland-dev libxkbcommon-dev \
        mold lld && \
    rm -rf /var/lib/apt/lists/*

# sccache (compiler cache; the runners point it at an S3 bucket). Static
# musl build from the upstream release, checksum-pinned.
ARG SCCACHE_VERSION=0.18.0
ARG SCCACHE_SHA256=45f1447fbe231e3037bde351ef70677dd212216c8d62ae7ca409fecc4d6acc89
RUN curl -fsSL -o /tmp/sccache.tgz \
        "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" && \
    echo "${SCCACHE_SHA256}  /tmp/sccache.tgz" | sha256sum -c - && \
    tar -xzf /tmp/sccache.tgz -C /tmp && \
    install -m 0755 /tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache /usr/local/bin/sccache && \
    rm -rf /tmp/sccache*
USER runner

LABEL org.opencontainers.image.title="GitHub Actions runner ${VERSION} with build toolchain" \
      org.opencontainers.image.description="ghcr.io/actions/actions-runner:${VERSION} plus build-essential, clang, cmake, pkg-config, OpenSSL, common Linux audio/input/windowing dev libraries, mold, lld and sccache." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.url="https://github.com/Galehuset/containers/tree/main/actions-runner" \
      org.opencontainers.image.source="https://github.com/Galehuset/containers"
