#!/bin/bash -e

# Ensure we have the latest image
docker pull couchbasebuild/check-builds:latest

# This script expects a /home/couchbase/check_builds to be available
# on the Docker host, and mounted into the Jenkins agent container at
# /home/couchbase/check_builds
cd /home/couchbase/check_builds
rm -rf product-metadata
git clone ssh://git@github.com/couchbase/product-metadata > /dev/null

echo
echo "Checking for missing builds..."
echo

docker run --rm -u couchbase \
    -w $(pwd) \
    -v /home/couchbase/jenkinsdocker-ssh:/home/couchbase/.ssh \
    -v /home/couchbase/check_builds:/home/couchbase/check_builds \
    -v /home/couchbase/check_builds/check_builds.ini:/etc/check_builds.ini \
    -v /san/latestbuilds:/home/couchbase/latestbuilds \
    couchbasebuild/check-builds \
        check_builds \
        -c /etc/check_builds.ini \
        product-metadata
