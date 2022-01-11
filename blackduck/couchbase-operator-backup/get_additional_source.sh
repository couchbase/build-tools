#!/bin/bash -ex

RELEASE=$1

# Create "bd-venv" in *parent* directory - run-scanner looks for this
python3 -m venv ../bd-venv
. ../bd-venv/bin/activate
pip install -r couchbase-operator-backup/requirements.txt

# Since we're about to run "repo" again, need to kill existing .repo dir
rm -rf .repo

# We need these repositories from the Server build as well.
# Use the Docker tag of the vanilla Dockerfile's FROM directive to
# determine the corresponding Server version.
VERSION=$(grep FROM couchbase-operator-backup/Dockerfile | sed -e 's/.*://')
mkdir server_src
cd server_src
repo init \
    -u ssh://git@github.com/couchbase/manifest \
    -m released/couchbase-server/${VERSION}.xml \
    -g backup
repo sync --jobs=8
rm -rf forestdb

# Prior to 7.0, backup was built with GOPATH, so we want to eliminate any
# "couchbase" packages before doing Black Duck signature scan. In 7.0,
# backup is built with Go modules, and the 'backup' group in the manifest
# already prunes out everything we don't need.
if [[ "${VERSION}" =~ ^6 ]]; then
    rm -rf go*/src/*/couchbase*
    # Also delete any go.mod files - leads to false positives in BD
    find go* -name go.mod -print0 | xargs -0 rm
fi
