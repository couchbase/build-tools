#!/bin/bash
set -e

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
[ "$(uname)" = "Darwin" ] && gid=$(id -g daemon) || gid=$(id -g)

# Build
docker build . -t escrow

docker run -it --name escrow --rm \
  -e PUID=$uid \
  -e PGID=$gid \
  -e PLATFORM=${PLATFORM} \
  -v ~/.ssh/known_hosts:/ssh/known_hosts \
  -v ${ssh_key}:/ssh/id_rsa \
  -v $(pwd):/app \
  -v ${host_path}:/output \
  -v /var/run/docker.sock:/var/run/docker.sock \
  escrow

# Test
cd $escrow

echo "Building for architecture $(uname -m)"
./build-couchbase-server-from-escrow.sh $escrow

echo "Finished"
