#!/bin/bash -e

source ./escrow_config

[ -z $2 ] && echo "Usage: ./go.sh [ssh_key] [output_path]" && exit 1
# `ssh_key` must have access to relevant repositories and
# should not have a passphrase to allow this process
# to run non-interactively
ssh_key=$1

# `host_path` is a directory on the host where the build
# will take place and artifacts will end up
host_path=$2
mkdir -p $host_path 2>/dev/null || :
pushd $host_path
host_path=$(pwd)
popd

# `escrow` contains the product and is where the artifacts
# are stored
escrow=${host_path}/$PRODUCT-$VERSION

uid=$(id -u)
gid=$(command -v getent && cut -d: -f3 < <(getent group docker) || id -g root)


# Build
docker build . -t escrow \
  --build-arg DOCKER_VERSION=${DOCKER_VERSION}
docker run -it --name escrow --rm \
  -e PUID=$uid \
  -e PGID=$gid \
  -e PLATFORM=${PLATFORM} \
  -v ${ssh_key}:/home/couchbase/.ssh/id_rsa \
  -v $(pwd):/app \
  -v ${host_path}:/output \
  -v /var/run/docker.sock:/var/run/docker.sock \
  escrow

# Test
cd $escrow
./build-couchbase-server-from-escrow.sh ubuntu18

echo "Finished"
