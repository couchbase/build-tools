#!/bin/bash -ex
set -x
PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbaselabs/agentmemory.git
pushd agentmemory
if git rev-parse --verify --quiet ${VERSION} >& /dev/null
then
    echo "Tag ${VERSION} exists, checking it out"
    git checkout ${VERSION}
else
    echo "No tag ${VERSION}, assuming master"
fi

# Detect scans the venv at ${venv} (= ${PROD_DIR}/.venv) that run-scanner is
# pointed at -- not any venv we create separately. The orchestrator makes it
# 3.11, but the SDK needs 3.12, so recreate it as 3.12 and install there.
venv="${venv:-${PROD_DIR}/.venv}"
rm -rf "${venv}"
uv venv --python 3.12 --python-preference only-managed "${venv}"
source "${venv}/bin/activate"
python -m ensurepip --upgrade --default-pip

# requirements.lock is the exact, hash-pinned closure the Docker image ships
# (uv pip compile --generate-hashes). Installing it makes the Detect PIP
# inspector report the production versions rather than a fresh PyPI re-resolve.
# The presence of hashes auto-enables pip's --require-hashes mode.
pip install -r requirements.lock

# Install the project itself (no deps, they are already pinned above) so the
# agentmemory package appears as the BOM root.
pip install -e . --no-deps
popd
