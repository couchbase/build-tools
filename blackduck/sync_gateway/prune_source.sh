#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3
TOOLS_DIR=$4

# clean up unnecessary source directories

# Remove un-needed ns_server git pull in for to use <!-- gozip tools --> purpose
rm -rf godeps/src/github.com/couchbase/ns_server
# Remove jQuery from scan CBD-2977
rm -rf godeps/src/github.com/couchbase/cbgt/rest/static/lib/jquery

# Remove beorn7 and golang_protobuf_extensions from scan CBD-3616
rm -rf godeps/src/github.com/beorn7
rm -rf godeps/src/github.com/matttproud/golang_protobuf_extensions

# nothing in the build repo should affect third-party reports
rm -rf cbbuild

# SGW wasn't built with Go modules prior to 3.1, so we shouldn't look at
# any go.mod files
if [ "3.1.0" != $(printf "3.1.0\n${VERSION}" | sort -n | head -1) ]; then
  find . -type f -name go.\?\?\? -delete
fi

# MB-43341, remove couchbase CB components from blackduck report
# use *couchbase*/$i to ensure these are from couchbase

for i in cbauth cbgt go-couchbase go-blip gocbconnstr gocb gocbcore gocbconnstr gomemcached goutils
do
  find . -type d -regex ".*couchbase.*\/$i.*" -exec rm -rf {} +
done
