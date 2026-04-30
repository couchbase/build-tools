#!/bin/bash -ex

# Ignore couchbase's own source
rm -rf goproj/src/github.com/couchbase/couchbase-operator/vendor/github.com/couchbase/gocbmgr

# Don't scan "build" repo
rm -rf cbbuild