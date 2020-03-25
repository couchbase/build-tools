#!/bin/bash

if [ -z $2 ]
then
  echo "Usage: go.sh [product] [release]"
fi

PRODUCT="$1"
RELEASE="$2"

docker build . -t manifest-tools

docker run --rm -i \
    -v /home/couchbase/check_missing_commits:/data/metadata \
    -v /home/couchbase/reporef:/data/reporef \
    -v /home/couchbase/jenkinsdocker-ssh:/home/couchbase/.ssh \
    manifest-tools ${PRODUCT} ${RELEASE}