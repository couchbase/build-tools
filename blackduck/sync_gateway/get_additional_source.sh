#!/bin/bash -e

export GOPROXY=http://goproxy.build.couchbase.com
export GOPRIVATE=github.com/couchbaselabs/go-fleecedelta
export GONOSUMDB="github.com/couchbaselabs/go-fleecedelta"

export PATH="$(${WORKSPACE}/build-tools/blackduck/jenkins/util/go-path-from-manifest.sh):$PATH"
