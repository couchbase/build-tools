#!/bin/bash -ex
git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
pushd couchbase-cloud
git checkout production

# Use the same go version used on self hosted runners
GO_VER=$(yq '.inputs.go-version.default' .github/actions/setup-go/action.yml)
cbdep install -d "${WORKSPACE}/extra" golang ${GO_VER}

export GONOSUMDB="github.com/prometheus/node_exporter"

# Get all node versions mentioned in build-and-deliver-predev action and install the latest
export NODE_VERSIONS=$(grep -oP '(?<=node-version: )\S+' .github/workflows/build-and-deliver-predev.yml | sed 's/[^0-9.]//g' | sort -V)
NODE_VER=$(echo "${NODE_VERSIONS}" | tail -n 1)
cbdep install -d "${WORKSPACE}/extra" nodejs ${NODE_VER}

# Ensure go + node are pathed
export PATH="${WORKSPACE}/extra/go${GO_VER}/bin:${WORKSPACE}/extra/nodejs-${NODE_VER}/bin:$PATH"

go mod download
popd
