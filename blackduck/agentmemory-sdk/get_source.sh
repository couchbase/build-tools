#!/bin/bash -ex
PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbaselabs/agentmemory-sdk.git
pushd agentmemory-sdk
git rev-parse --verify --quiet ${VERSION} && git checkout ${VERSION} || echo "No tag ${VERSION}, using main"

# Detect scans the venv at ${venv} (= ${PROD_DIR}/.venv) that run-scanner is
# pointed at -- not any venv we create separately. The orchestrator makes it
# 3.11, but the SDK needs 3.12, so recreate it as 3.12 and install there.
venv="${venv:-${PROD_DIR}/.venv}"
rm -rf "${venv}"
uv venv --python 3.12 --python-preference only-managed "${venv}"
source "${venv}/bin/activate"
python -m ensurepip --upgrade --default-pip

# No lock file: install the loose deps from requirements.txt (pip resolves the
# transitive closure), then the project itself as the BOM root.
pip install -r requirements.txt
pip install . --no-deps
popd
