#!/bin/bash -ex
git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
pushd couchbase-cloud
git checkout production

# Use the same go version used on self hosted runners
GO_VER=$(yq '.inputs.go-version.default' .github/actions/setup-go/action.yml)
cbdep install -d "${WORKSPACE}/extra" golang ${GO_VER}

export GONOSUMDB="github.com/prometheus/node_exporter"

# Get all node versions mentioned in build-and-deliver-predev workflow
# (including the default value for the setup-node action). This will be
# used in `get_additional_source.sh` to determine which node version to
# use for each package.
export NODE_VERSIONS=$( (
    grep -oP '(?<=node-version: )\S+' .github/workflows/build-and-deliver-predev.yml | sed 's/[^0-9.]//g'
    yq '.inputs.node-version.default' .github/actions/setup-node/action.yml
) | sort -V)
echo "${NODE_VERSIONS}"

# Ensure go is pathed
export PATH="${WORKSPACE}/extra/go${GO_VER}/bin:$PATH"

go mod download
popd
