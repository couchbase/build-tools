#!/bin/bash -ex

# QQQ This can be removed when build manifests contain all source

echo "Getting dependencies source ..."
cd goproj/src/github.com/couchbase/couchbase-operator/
make dep
