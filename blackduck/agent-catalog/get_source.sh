#!/bin/bash -ex
set -x
PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbaselabs/agent-catalog.git
pushd agent-catalog
if git rev-parse --verify --quiet ${VERSION} >& /dev/null
then
    echo "Tag ${VERSION} exists, checking it out"
    git checkout ${VERSION}
else
    echo "No tag ${VERSION}, assuming main/master"
fi
uv venv --python 3.12 --python-preference only-managed test
source test/bin/activate
python -m ensurepip --upgrade --default-pip

# Blackduck picks up torch as agentc/sentence-transformers' dependency.
# Torch on PyPI is Nvidia enabled.  AI team has confirmed we don't deploy to
# hardware backed by Nvidia drivers.  We need to exclude these.
# https://stackoverflow.com/questions/78947332/how-to-install-torch-without-nvidia
# Use the download.pytorch.org index for CPU-only wheels
pip install torch --index-url https://download.pytorch.org/whl/cpu

# libs/agentc requires python 3.12.
# Blackduck scan currently uses 3.11, does not support 3.12
# If I install modules using python 3.12, blackduck doesn't recognize any of them
# As a workaround, I have to ignore python version requirement during install
pip install libs/agentc
pip install -r requirements.txt
#pip install libs/agentc --ignore-requires-python
#pip install -r requirements.txt --ignore-requires-python
popd
