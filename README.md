# containers

Small container images for [Galehuset](https://github.com/Galehuset)'s homelab Kubernetes clusters, mostly light
tweaks of existing public images. Each top-level folder with a `Dockerfile` is built by GitHub Actions and pushed to
`ghcr.io/galehuset/containers/<folder>`.

| Image | What it is |
|---|---|
| [`actions-runner`](actions-runner/) | The official GitHub Actions runner plus a build toolchain (build-essential, clang, cmake, pkg-config, OpenSSL, common Linux audio/input/windowing dev libraries), the `mold` and `lld` linkers, and `sccache`. For self-hosted runners that build native code, e.g. Rust. |
| [`opennms-horizon`](opennms-horizon/) | Unofficial rebuild of the official OpenNMS Horizon image on UBI 9, for x86-64 CPUs without x86-64-v3 (AVX2). OpenNMS itself is unmodified. See its [README](opennms-horizon/README.md). |

## Tags

- `<version>`: if a Dockerfile has a top-level `ARG VERSION=x`, usually the upstream release it packages
- `<git sha>` and `latest`: every build of `main`

Pull requests build every image without pushing.

## Updates

Renovate keeps base images and GitHub Actions current: minor and patch updates merge automatically once the image
build passes; major updates wait for review.

## Caveats

These are built for our own use. They're public because they're small tweaks of public images, not because they're
supported products. Upstream licenses apply to the software inside each image.
