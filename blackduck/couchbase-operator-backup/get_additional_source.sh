#!/bin/bash -ex

RELEASE=$1

# Grab the most recent supported version of go to use when finding the version
# cbbackupmgr was built with and running the scan
#
# Note: we're in a venv and about to jump into a second, so write the path
# change to _OLD_VIRTUAL_PATH to trick `activate` into doing what we want.
#
# If we were to write directly to PATH, `activate` would overwrite it with the
# contents of _OLD_VIRTUAL_PATH which was set when the outer venv was activated
# and does not include our change. Similarly, if we write to PATH *after*
# activating bd-venv below, when that env deactivates, _OLD_VIRTUAL_PATH (set
# at the time of activation) will be flipped in, reversing our modification.
export _OLD_VIRTUAL_PATH="$(${WORKSPACE}/build-tools/blackduck/jenkins/util/go-path-latest.sh):$PATH"

# Create "bd-venv" in *parent* directory - run-scanner looks for this
python3 -m venv ../bd-venv
. ../bd-venv/bin/activate
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
