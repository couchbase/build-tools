#!/usr/bin/env bash
set -e

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <gerrit-version>"
    exit 1
fi

# Set the major and minor version variables
IFS='.' read -r -a VERSION_PARTS <<< "$VERSION"
MAJOR=${VERSION_PARTS[0]}
MINOR=${VERSION_PARTS[1]}

# A full x.y.z builds against that release tag rather than the moving stable
# branch, so the jars match the server's API exactly
GERRIT_BRANCH=
[ -n "${VERSION_PARTS[2]}" ] && GERRIT_BRANCH=v$VERSION

# docker cp into an existing dir nests the output inside it
if [ -e "./plugins-$VERSION" ]; then
    echo "./plugins-$VERSION already exists, move it aside first"
    exit 1
fi

JDK_VERSION=17
if [ "$MAJOR" = "3" ]; then
    if [ "$MINOR" -lt "8" ]; then
        JDK_VERSION=11
    elif [ "$MINOR" -ge "12" ]; then
        JDK_VERSION=21
    fi
fi

docker build . --build-arg JDK_VERSION=$JDK_VERSION --build-arg GERRIT_MAJOR_VERSION=$MAJOR --build-arg GERRIT_MINOR_VERSION=$MINOR --build-arg GERRIT_BRANCH=$GERRIT_BRANCH -t local/gerrit-plugin-factory --progress plain

CONTAINER_ID=$(docker create local/gerrit-plugin-factory)
trap "docker rm ${CONTAINER_ID}" EXIT
docker cp ${CONTAINER_ID}:/plugins ./plugins-$VERSION
