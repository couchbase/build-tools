#!/bin/sh -ex

# We pass the userid in at runtime and allocate it to the in-container user
# to ensure files written to mountpoints are owned by the host user
usermod -o -u "${PUID}" couchbase

# The host's docker group is passed in at runtime so we can let the container
# user access the docker socket
groupmod -o -g "${PGID}" couchbase

# trigger build_escrow pointing at our volume mountpoint
su -c "/app/build_escrow.sh /output" couchbase
