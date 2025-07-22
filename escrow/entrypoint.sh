#!/bin/sh -e

# We pass the userid in at runtime and allocate it to the in-container user
# to ensure files written to mountpoints are owned by the host user
usermod -o -u "${PUID}" couchbase

# The host's docker group is passed in at runtime so we can let the container
# user access the docker socket
groupmod -o -g "${PGID}" couchbase

# Check Docker socket group and ensure couchbase user can access it
if [ -S /var/run/docker.sock ]; then
  DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  echo "Docker socket owned by group: $DOCKER_SOCK_GID"

  # Create or modify docker group to match socket group
  if ! getent group docker > /dev/null 2>&1; then
    groupadd -g "$DOCKER_SOCK_GID" docker
    echo "Created docker group with GID $DOCKER_SOCK_GID"
  else
    groupmod -g "$DOCKER_SOCK_GID" docker
    echo "Modified docker group to GID $DOCKER_SOCK_GID"
  fi

  # Add couchbase user to docker group
  usermod -a -G docker couchbase
  echo "Added couchbase user to docker group"
fi

# Add couchbase user to root group as backup
usermod -a -G root couchbase

# trigger build_escrow pointing at our volume mountpoint
su -c "/app/build_escrow.sh /output" couchbase
