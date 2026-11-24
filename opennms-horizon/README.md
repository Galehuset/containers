# OpenNMS Horizon on UBI 9 (unofficial)

`ghcr.io/galehuset/containers/opennms-horizon:<horizon version>`

An **unofficial** rebuild of the official [`opennms/horizon`](https://hub.docker.com/r/opennms/horizon)
image for x86-64 CPUs that lack **x86-64-v3** (AVX2, BMI2, FMA, ...) — for
example Intel Ivy Bridge Xeons.

## Why

Since Horizon 36 the official image is built on Red Hat UBI 10, whose glibc
requires x86-64-v3. On older CPUs every binary in it, including the JVM, dies
at start:

```
Fatal glibc error: CPU does not support x86-64-v3
```

Horizon itself is Java and runs fine on those CPUs; only the base image
doesn't.

## What it is

- The `/opt/opennms` tree, `entrypoint.sh`, `health.sh` and confd templates
  are copied **unchanged** from `opennms/horizon:<version>`.
- They sit on OpenNMS' own UBI 9 base, `opennms/deploy-base:ubi9-*-jre-21`
  (same Java major as the official image), with the same packages and
  `opennms` (10001) user the official Dockerfile installs.
- Usage, environment variables, volumes and ports are the same as the
  official image — see the [Horizon documentation](https://docs.opennms.com/horizon/latest/)
  and its container notes.

Checked by running the image's JVM under QEMU with `-cpu IvyBridge`: the
official image fails with the error above, this one runs.

## Tags

- `<version>` — the Horizon release it packages (from `ARG VERSION` in the
  Dockerfile), e.g. `36.0.4`
- `<git sha>` and `latest` — every build of `main`

## Caveats

- Not built, tested or supported by The OpenNMS Group. For problems that
  also happen with the official image, report them upstream; for anything
  specific to this rebuild, open an issue here.
- Native libraries (jicmp, jrrd2) come from the UBI 9 base, not from the
  official image.
- When bumping across Horizon majors, compare against upstream's
  `opennms-container/core/Dockerfile` in case the runtime layer changed.

## License

OpenNMS Horizon is licensed under the AGPL-3.0-or-later; this image
redistributes it unmodified. Source: <https://github.com/OpenNMS/opennms>.
