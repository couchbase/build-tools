#!/bin/bash -e

export GOPROXY=http://goproxy.build.couchbase.com
export GOPRIVATE=github.com/couchbaselabs/go-fleecedelta
export GONOSUMDB="github.com/couchbaselabs/go-fleecedelta"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export PATH="$(${SCRIPT_DIR}/../jenkins/util/get-go-path.sh):$PATH"
