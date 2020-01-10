#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}
PROD_NAME=$(basename $PRODUCT_PATH)

# Reset src directory and cd into it
SRC_DIR="${WORKSPACE}/src"
rm -rf "${SRC_DIR}"
mkdir "${SRC_DIR}"
cd "${SRC_DIR}"

# If the product doesn't have a bespoke get_source.sh, then look up the
# build manifest and sync that
if [ -x "${WORKSPACE}/build-tools/blackduck/${PROD_NAME}/get_source.sh" ]; then
    "${WORKSPACE}/build-tools/blackduck/${PROD_NAME}/get_source.sh" ${PRODUCT} ${RELEASE} ${VERSION} ${BLD_NUM}
else
    pushd "${WORKSPACE}"

    # Sync build-manifests
    if [ ! -e build-manifests ]; then
        git clone git://github.com/couchbase/build-manifests
    else
        (cd build-manifests && git pull)
    fi

    # Find the requests build manifest
    cd build-manifests
    SHA=$(git log --format='%H' --grep "^$PRODUCT $RELEASE build $VERSION-$BLD_NUM$")
    if [ -z "${SHA}" ]; then
        echo "Build ${PRODUCT} ${RELEASE} ${VERSION}-${BLD_NUM} not found!"
        exit 1
    fi
    MANIFEST=$(git diff-tree --no-commit-id --name-only -r $SHA)

    # Back to the src directory
    popd

    echo "Syncing manifest $MANIFEST at $SHA"
    echo ================================
    repo init -u git://github.com/couchbase/build-manifests -b $SHA -g all -m $MANIFEST
    repo sync --jobs=16
    repo manifest -r > manifest.xml
    echo
fi

# If the build database knows about this build, update the blackduck metadata
DBAPI_PATH=products/${PRODUCT}/releases/${RELEASE}/versions/${VERSION}/builds/${BLD_NUM}
status=$(curl -s -w "%{http_code}" --head -o /dev/null \
    http://dbapi.build.couchbase.com:8000/v1/${DBAPI_PATH})
if [ "${status}" = "200" ]; then
    curl -d '{"blackduck_scan": true}' -X POST -H "Content-Type: application/json" \
        http://dbapi.build.couchbase.com:8000/v1/${DBAPI_PATH}/metadata
fi

# Product-specific script for getting additional sources
if [ -x "${WORKSPACE}/build-tools/blackduck/${PRODUCT}/get_additional_source.sh" ]; then
  "${WORKSPACE}/build-tools/blackduck/${PRODUCT}/get_additional_source.sh" ${RELEASE}
fi

# May need to override this per-product?
find . -name .git -print0 | xargs -0 rm -rf
find . -name .repo -print0 | xargs -0 rm -rf

# Product-specific script for pruning unwanted sources
if [ -x "${WORKSPACE}/build-tools/blackduck/${PRODUCT}/prune_source.sh" ]; then
  "${WORKSPACE}/build-tools/blackduck/${PRODUCT}/prune_source.sh" ${RELEASE}
fi

# Product-specific config for Synopsis Detect
if [ -e "${WORKSPACE}/build-tools/blackduck/${PRODUCT}/detect-config.json" ]; then
  CONFIG_ARG="-c ${WORKSPACE}/build-tools/blackduck/${PRODUCT}/detect-config.json"
fi

# If doing dry-run, clean out any old archives
if [ "x${DRY_RUN}" = "xtrue" ]; then
  export DRY_RUN_ARG="-n"
  rm -rf ~/blackduck/runs/*
fi

# Invoke scan script
"${WORKSPACE}/build-tools/blackduck/jenkins/detect-scan/run-scanner" \
  ${DRY_RUN_ARG} \
  ${CONFIG_ARG} \
  --token ~/.ssh/blackduck-token.txt \
  --pdf

# Copy up dry-run archives
if [ "x${DRY_RUN}" = "xtrue" ]; then
  echo Copying dryrun archives...
  cp ~/blackduck/runs/detect-run*.zip ${WORKSPACE}
fi
