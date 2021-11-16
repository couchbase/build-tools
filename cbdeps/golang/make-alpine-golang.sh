#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

GOVER=$1
chk_set GOVER

GOLANG_IMAGE=golang:${GOVER}-alpine3.14
docker pull ${GOLANG_IMAGE}
docker rm -f gopuller
docker run -d --name gopuller ${GOLANG_IMAGE} sleep 10000
function cleanup {
  docker rm -f gopuller
  docker rmi ${GOLANG_IMAGE}
}
trap cleanup EXIT

# "docker cp" will conveniently spit out a tar when asked to output to stdout
docker cp gopuller:/usr/local/go - | gzip -c > go${GOVER}.linux-x64-musl.tar.gz
