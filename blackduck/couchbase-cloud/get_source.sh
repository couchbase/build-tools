#!/bin/bash -ex
git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
git clone ssh://git@github.com/couchbase/direct-nebula.git
git clone ssh://git@github.com/couchbase/data-api.git
git clone ssh://git@github.com/couchbase/regulator.git ../extra/regulator

# Use the same go version used on self hosted runners
GO_VER=$(yq '.inputs.version.default' couchbase-cloud/.github/actions/install-go-self-hosted/action.yml)
cbdep install -d "${WORKSPACE}/extra" golang ${GO_VER}

export GONOSUMDB="github.com/prometheus/node_exporter"

# Install node version used in fm-ui-v2 (with failover to 20.9.0)
NODE_VER_FILE=couchbase-cloud/cmd/fm-ui-v2/Dockerfile
PATTERN="^\# node\/[0-9]+\.[0-9]+\.[0-9]+$"
DEFAULT_VERSION=20.9.0
if grep -Eq "${PATTERN}" "${NODE_VER_FILE}" >&/dev/null; then
    NODE_VER=$(grep -E "${PATTERN}" "${NODE_VER_FILE}" | sed "s/.*\///")
else
    NODE_VER=${DEFAULT_VERSION}
fi
cbdep install -d "${WORKSPACE}/extra" nodejs ${NODE_VER}

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
