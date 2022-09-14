#!/bin/bash -e
cat <<EOF
export GOPROXY=http://goproxy.build.couchbase.com
export GOPRIVATE=github.com/couchbaselabs/go-fleecedelta
export GONOSUMDB="github.com/couchbaselabs/go-fleecedelta"
EOF
