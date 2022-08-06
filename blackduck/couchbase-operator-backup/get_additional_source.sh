#!/bin/bash -ex

RELEASE=$1

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
VERSION=$(
    docker run --rm ${SERVER_DOCKER_VER} cat /opt/couchbase/VERSION.txt \
    | sed 's/-.*//'
)
mkdir server_src
cd server_src
repo init \
    -u ssh://git@github.com/couchbase/manifest \
    -m released/couchbase-server/${VERSION}.xml \
    -g backup
repo sync backup cbauth gomemcached go-couchbase

# Also take a peek at cbbackupmgr from there and determine what Go version
# was used to compile it
docker run --rm -v $(pwd):/mnt ${SERVER_DOCKER_VER} \
    cp /opt/couchbase/bin/cbbackupmgr /mnt
GOVERSION=$(go version cbbackupmgr | sed -Ee 's/^.*go([0-9]+\.[0-9]+\.[0-9]+)$/\1/')

# Cons up a black-duck-manifest for Golang
cat <<EOF > "${WORKSPACE}/src/${PRODUCT}-black-duck-manifest.yaml"
components:
  go programming language:
    bd-id: 6d055c2b-f7d7-45ab-a6b3-021617efd61b
    versions: [ ${GOVERSION} ]
EOF
