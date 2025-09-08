#!/bin/bash -ex

# example usage
# get_source.sh vulcan 1.0.0 1.0.0 9999

# Set to "vulcan", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your
# scan-config.json specified a release key for this version, that value
# will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

git clone ssh://git@github.com/couchbasecloud/couchbase-cloud.git
pushd couchbase-cloud
git checkout $RELEASE
# Use the same go version used on self hosted runners
GO_VER=$(yq '.inputs.go-version.default' .github/actions/setup-go/action.yml)
cbdep install -d "${WORKSPACE}/extra" golang ${GO_VER}
export PATH="${WORKSPACE}/extra/go${GO_VER}/bin:$PATH"
export GOPATH=${WORKSPACE}/extra/pkg/mod
mkdir -p ${GOPATH}

cd cmd/dp-runtime-agent
go mod init couchbase-cloud/cmd/dp-runtime-agent
cat ${PROD_DIR}/go.mod.replace >> go.mod
go mod tidy
