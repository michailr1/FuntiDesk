# FUNTIDESK ADR-004: own hbbs/hbbr image.
# Same layout as the upstream "classic" rustdesk-server image (scratch,
# binaries in /usr/bin, working directory /root with the server identity).
# The static binaries come from the pinned GitHub release and are verified
# by scripts/server/build-image.sh before this build.
FROM scratch
COPY hbbs hbbr /usr/bin/
WORKDIR /root
