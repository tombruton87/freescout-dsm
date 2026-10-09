# The setup container: Docker's own CLI image, with what run.sh needs besides.
# util-linux-misc has nsenter, for the few things only root on the Synology
# itself can do (notifications, installing a package update).
FROM docker:27-cli
RUN apk add --no-cache bash curl iproute2 coreutils gawk tar gzip procps tzdata jq util-linux-misc openssl
