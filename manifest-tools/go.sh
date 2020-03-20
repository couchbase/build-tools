#!/bin/bash

PRODUCT="$1"
RELEASE="$2"

docker build . -t manifest-tools
docker run --rm -it \
    -v /home/couchbase/check_missing_commits:/home/couchbase/check_missing_commits \
    -v /home/couchbase/reporef:/home/couchbase/reporef \
    -v /home/couchbase/jenkinsdocker-ssh:/home/couchbase/.ssh \
    manifest-tools ${PRODUCT} ${RELEASE}
