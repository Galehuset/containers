# trivy-watch for hosts without Nix (VyOS): the same script as
# ~/Nix/common/trivy-watch/trivy-watch.py (keep the copy in sync), with the
# trivy client and the docker CLI. On VyOS it talks to podman's
# Docker-compatible socket via DOCKER_HOST=unix:///run/podman/podman.sock,
# so the script needs no podman-specific code.
# Keep the trivy version in step with the kubeinetes Trivy server.
FROM mirror.gcr.io/aquasec/trivy:0.76.1

RUN apk add --no-cache python3 docker-cli

COPY trivy-watch.py /usr/local/bin/trivy-watch.py

ENV TEXTFILE_DIR=/textfile \
    STATE_DIR=/state \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "-I", "/usr/local/bin/trivy-watch.py"]
