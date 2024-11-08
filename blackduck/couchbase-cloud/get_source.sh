#!/bin/bash -ex
git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
git clone ssh://git@github.com/couchbase/direct-nebula.git
git clone ssh://git@github.com/couchbase/data-api.git
git clone ssh://git@github.com/couchbase/regulator.git ../extra/regulator

# Use the same go version used on self hosted runners
GO_VER=$(yq '.inputs.version.default' couchbase-cloud/.github/actions/install-go-self-hosted/action.yml)
cbdep install -d "${WORKSPACE}/extra" golang ${GO_VER}

export GONOSUMDB="github.com/prometheus/node_exporter"

# Get all node versions mentioned in build-and-deliver-predev action and install the latest
export NODE_VERSIONS=$(grep -oP '(?<=node-version: )\S+' couchbase-cloud/.github/workflows/build-and-deliver-predev.yml | sed 's/"//g' | sort -V)
cbdep install -d "${WORKSPACE}/extra" nodejs $(echo "${NODE_VERSIONS}" | tail -n 1)

# Ensure go + node are pathed
export PATH="${WORKSPACE}/extra/go${GO_VER}/bin:${WORKSPACE}/extra/nodejs-${NODE_VER}/bin:$PATH"

echo "replace github.com/couchbasecloud/couchbase-cloud => ../couchbase-cloud" >> direct-nebula/go.mod
echo "replace github.com/couchbasecloud/couchbase-cloud => ../couchbase-cloud" >> data-api/go.mod
echo "replace github.com/couchbase/regulator => ../../extra/regulator" >> data-api/go.mod
echo "replace github.com/couchbase/regulator => ../../extra/regulator" >> direct-nebula/go.mod

pushd couchbase-cloud
git checkout production
popd

for repo in couchbase-cloud direct-nebula data-api; do
    pushd ${repo}
    go mod download
    popd
done
