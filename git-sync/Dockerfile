FROM alpine:3.24

# install required packages (git, bash, inotify-tools, openssh-client, ca-certificates)
RUN apk add --no-cache git bash inotify-tools openssh-client ca-certificates && \
    update-ca-certificates

# copy script
COPY git-sync.sh /usr/local/bin/git-sync.sh
RUN chmod +x /usr/local/bin/git-sync.sh

WORKDIR /repo
ENTRYPOINT ["/usr/local/bin/git-sync.sh"]
