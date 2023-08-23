#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}
git clone ssh://git@github.com/couchbase/license-reviews

if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate

cd ${WORKSPACE}/build-tools/blackduck/jenkins/check-licences
pip3 install -r requirements.txt

export LANG=en_US.UTF-8

set +e
./check-component-lic.py \
    ${PRODUCT} ${VERSION} \
    -c ~/.ssh/blackduck-creds.json \
    -d ${WORKSPACE}/license-reviews
retval=$?
set -e

cd ${WORKSPACE}/license-reviews
git add ${PRODUCT_PATH} license-data
git config --global push.default simple
git diff --quiet && git diff --staged --quiet || git commit \
    -m "Update report for ${PRODUCT} ${VERSION}" \
    --author='Couchbase Build Team <build-team@couchbase.com>'
git push

exit $retval