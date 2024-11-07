#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}

cd ${WORKSPACE}
"${WORKSPACE}/build-tools/utilities/clean_git_clone" ssh://git@github.com/couchbase/license-reviews

cd ${WORKSPACE}/build-tools/blackduck/jenkins/check-licences

export LANG=en_US.UTF-8

set +e
uv run check-component-lic.py \
    ${PRODUCT} ${VERSION} \
    -c ~/.ssh/blackduck-creds.json \
    -d ${WORKSPACE}/license-reviews
retval=$?
set -e

cd ${WORKSPACE}/license-reviews
git add ${PRODUCT_PATH} license-data
git config push.default simple
git diff --quiet && git diff --staged --quiet || git commit \
    -m "Update report for ${PRODUCT} ${VERSION}" \
    --author='Couchbase Build Team <build-team@couchbase.com>'
if ! $SKIP_GIT_PUSH; then
    git push
fi

exit $retval