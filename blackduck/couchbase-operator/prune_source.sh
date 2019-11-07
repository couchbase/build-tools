#!/bin/bash -ex

# Ignore couchbase's own source
rm -rf ${WORKSPACE}/src/goproj/src/github.com/couchbase/couchbase-operator/vendor/github.com/couchbase/gocbmgr
