#!/bin/bash -e

DOCKERFILE=$1

# Find the last FROM line in the Dockerfile and cut off the image name
base=$(tac ${DOCKERFILE} | grep -m1 '^FROM' | cut -d' ' -f2)

if [ "${base}" = "scratch" ]; then
    echo "Not updating 'scratch' base image"
else
    echo "Updating base image ${base}"
    docker pull ${base}
fi
