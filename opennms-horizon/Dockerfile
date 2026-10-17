# OpenNMS Horizon on a UBI 9 base.
#
# Since Horizon 36 the official image is built on UBI 10, whose glibc needs
# x86-64-v3 (AVX2); on older CPUs (e.g. Ivy Bridge Xeons) it dies at start
# with "Fatal glibc error: CPU does not support x86-64-v3". Horizon itself is
# Java, so this takes the finished /opt/opennms tree, entrypoint and confd
# templates from the official image and puts them on OpenNMS' own UBI 9 +
# Java 21 deploy-base (the same JRE major the official 36 image uses).
#
# The runtime layer below mirrors opennms-container/core/Dockerfile in
# OpenNMS/opennms; keep it in step when bumping across major versions.
ARG VERSION=36.0.5

FROM docker.io/opennms/horizon:${VERSION} AS horizon

FROM docker.io/opennms/deploy-base:ubi9-3.6.11.b376-jre-21

ARG VERSION
SHELL ["/bin/bash", "-c"]

# Same packages and user as the official image.
RUN microdnf -y install diffutils hostname jrrd2 jq rrdtool && \
    microdnf clean all && \
    rm -rf /var/cache/yum && \
    groupadd --gid 10001 opennms && \
    adduser --uid 10001 --gid 10001 --home /opt/opennms --no-create-home \
            --shell /usr/bin/bash opennms

# /opt/opennms already has the official image's layout: etc-pristine, the
# share/{rrd,reports,mibs} -> /opennms-data symlinks, group-writable dirs.
COPY --from=horizon --chown=10001:0 /opt/opennms /opt/opennms
COPY --from=horizon --chown=10001:0 /opennms-data /opennms-data
COPY --from=horizon --chown=10001:0 /opt/opennms-etc-overlay /opt/opennms-etc-overlay
COPY --from=horizon --chown=10001:0 /opt/opennms-jetty-webinf-overlay /opt/opennms-jetty-webinf-overlay
COPY --from=horizon --chown=10001:0 /opt/opennms-overlay /opt/opennms-overlay
COPY --from=horizon --chown=10001:0 /etc/confd /etc/confd
COPY --from=horizon --chown=10001:0 /entrypoint.sh /health.sh /

RUN install -d -m 775 -o 10001 -g 0 /var/log && \
    chmod -R g=u /opt/opennms/etc && \
    find /opt/opennms/data /opt/opennms/system /opennms-data -type d -print0 | xargs -0 chmod g=u

# Shown on the GHCR package page. Unofficial: not built or supported by
# The OpenNMS Group.
LABEL org.opencontainers.image.title="OpenNMS Horizon ${VERSION} (UBI 9, unofficial)" \
      org.opencontainers.image.description="Unofficial rebuild of the official opennms/horizon:${VERSION} image on a UBI 9 base, for x86-64 CPUs without x86-64-v3 (AVX2), e.g. Ivy Bridge. OpenNMS itself is unmodified." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.url="https://github.com/Galehuset/containers/tree/main/opennms-horizon" \
      org.opencontainers.image.source="https://github.com/Galehuset/containers" \
      org.opencontainers.image.documentation="https://docs.opennms.com/horizon/latest/" \
      org.opencontainers.image.base.name="docker.io/opennms/deploy-base:ubi9-3.6.11.b376-jre-21"

WORKDIR /opt/opennms
USER 10001
ENTRYPOINT [ "/entrypoint.sh" ]
STOPSIGNAL SIGTERM
CMD [ "-h" ]
ENV JAVA_OPTS="-Xmx1024m -XX:MaxMetaspaceSize=512m"
ENV OPENNMS_EXECUTION_ENVIRONMENT=container
VOLUME [ "/opt/opennms/etc", "/opt/opennms-etc-overlay", "/opennms-data" ]
EXPOSE 8980 8101 1162/udp 10514/udp
