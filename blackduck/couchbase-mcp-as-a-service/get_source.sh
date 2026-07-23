#!/bin/bash -ex


# Set to "couchbase-mcp-as-a-service", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your
# scan-config.json specified a release key for this version, that value
# will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

git clone https://github.com/couchbaselabs/couchbase-mcp-as-a-service
pushd couchbase-mcp-as-a-service
if [[ "$RELEASE" == "release" ]]; then
  git fetch --all --tags
  TAG=$(git for-each-ref --sort=-creatordate --format '%(refname:short)' refs/tags | head -n 1)
  git checkout $TAG
else
  git checkout $RELEASE
fi

rm -rf ami deprecated tests sandbox

# Extract python version from uv.lock, fall back to default if it is not found
PYTHON_VERSION=$(awk -F '[="> ]+' '/requires-python/ {print $2}' uv.lock)
PYTHON_VERSION=${PYTHON_VERSION:-3.12}

# Remove dev from optional-dependencies in uv.lock to exclude from Black Duck scan
# "uv tree" commands do not filter "extra" or optional-dependencies.
# Hence optional dev is not excluded by "uv tree --no-dev" or similar commands
# We need to modify uv.lock here before doing the actual scanning
sed -i '/^\[package\.optional-dependencies\]/,/^\[/{
  /^dev = \[/,/^]/d
}' uv.lock

uv venv --python ${PYTHON_VERSION} ${WORKSPACE}/mypyenv
source ${WORKSPACE}/mypyenv/bin/activate
popd
