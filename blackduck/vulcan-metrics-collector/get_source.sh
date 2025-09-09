#!/bin/bash -ex

# example usage
# get_source.sh vulcan 1.0.0 1.0.0 9999

# Set to "vulcan-metrics-collector", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your
# scan-config.json specified a release key for this version, that value
# will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

git clone https://github.com/couchbaselabs/vulcan-core
pushd vulcan-core
if [[ "$RELEASE" == "release" ]]; then
  git fetch --all --tags
  TAG=$(git for-each-ref --sort=-creatordate --format '%(refname:short)' refs/tags | head -n 1)
  git checkout $TAG
else
  git checkout $RELEASE
fi

# Extract POETRY_VERSION and PYTHON_VERSION with defaults
PYTHON_VERSION=$(grep "^PYTHON_VERSION :=" Makefile | cut -d' ' -f3)
PYTHON_VERSION=${PYTHON_VERSION:-3.11}
POETRY_VERSION=$(grep "^POETRY_VERSION :=" Makefile | cut -d' ' -f3)
POETRY_VERSION=${POETRY_VERSION:-1.8.3}

uv venv --python ${PYTHON_VERSION} ${WORKSPACE}/mypyenv
source ${WORKSPACE}/mypyenv/bin/activate
python -m ensurepip --upgrade --default-pip
pip install poetry==${POETRY_VERSION}
popd
mkdir -p ${PRODUCT}/operators
mv vulcan-core/config ${PRODUCT}/.
mv vulcan-core/workflow ${PRODUCT}/.
mv vulcan-core/docker ${PRODUCT}/.
mv vulcan-core/operators/common ${PRODUCT}/operators
rm -rf vulcan-core
