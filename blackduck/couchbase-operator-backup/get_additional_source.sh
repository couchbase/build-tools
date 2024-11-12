#!/bin/bash -ex

RELEASE=$1

# Grab the most recent supported version of go to use when finding the version
# cbbackupmgr was built with and running the scan

# Install python requirements - the main scripts have ensured that there's
# an empty venv activated for us to populate, and that this same venv will
# be used by Detect
pip install -r couchbase-operator-backup/requirements.txt

# Since we're about to run "repo" again, need to kill existing .repo dir
rm -rf .repo

# We need some repositories from the Server build as well.
# Use the Docker tag of the vanilla Dockerfile's FROM directive to
# determine the corresponding Server version.
SERVER_DOCKER_VER=$(
    sed -nE 's/^FROM +(couchbase\/server[^[:space:]]+).*/\1/p' \
        couchbase-operator-backup/Dockerfile \
    | head -1
)

# We need to pull some files out of the server container, so create
# one up front and use docker cp (to avoid mount headaches, since
# we're running a container in a container)
container=$(docker create ${SERVER_DOCKER_VER})
trap "docker rm ${container}" EXIT

docker cp ${container}:/opt/couchbase/VERSION.txt .

SERVER_VERSION=$(sed 's/-.*//' VERSION.txt)

mkdir server_src
cd server_src
repo init \
    -u ssh://git@github.com/couchbase/manifest \
    -m released/couchbase-server/${SERVER_VERSION}.xml \
    -g backup
repo sync backup cbauth gomemcached go-couchbase

# Also take a peek at cbbackupmgr from there and determine what Go version
# was used to compile it
docker cp ${container}:/opt/couchbase/bin/cbbackupmgr .

GOVERSION=$(go version cbbackupmgr | sed -Ee 's/^.*go([0-9]+\.[0-9]+\.[0-9]+)$/\1/')

# Cons up a black-duck-manifest for Golang
cat <<EOF > "${WORKSPACE}/src/${PRODUCT}-black-duck-manifest.yaml"
components:
  go programming language:
    bd-id: 6d055c2b-f7d7-45ab-a6b3-021617efd61b
    versions: [ ${GOVERSION} ]
EOF

deactivate
