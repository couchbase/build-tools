#!/bin/bash

RELEASE=$1

shopt -s extglob

# Third-party go code
rm -rf godeps/src/*/!(couchbase*)
rm -rf godeps/src/github.com/couchbase/ns_server

# Build isn't primarily about SGW
rm -rf cbbuild

echo @@@@@@@@@@@@@@@@@@@@@@@@@
echo "sync_gateway ${RELEASE}"
echo @@@@@@@@@@@@@@@@@@@@@@@@@

cloc --quiet .
