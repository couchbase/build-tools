#!/usr/bin/env bash
set -ex

mkdir -p plugins

docker build . -t local/gerrit-plugin-factory --progress plain

CONTAINER_ID=$(docker create local/gerrit-plugin-factory)
trap "docker rm ${CONTAINER_ID}" EXIT
docker cp ${CONTAINER_ID}:/plugins .
