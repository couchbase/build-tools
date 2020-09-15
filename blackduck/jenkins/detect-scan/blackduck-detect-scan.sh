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

# Product-specific config for Synopsys Detect
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
  # Don't go on to add manual entries
  exit
fi

do-manual-manifest() {
  venv="${WORKSPACE}/.venv"
  if [ ! -d "${venv}" ]; then
    python3 -m venv "${venv}"
  fi
  source "${venv}/bin/activate"

  cd "${WORKSPACE}/build-tools/blackduck/jenkins/detect-scan"
  pip3 install -r manual-manifest-requirements.txt

  echo "Loading product-specific Black Duck manifest ${manifest[0]}"
  ./update-manual-manifest -d \
      -c ~/.ssh/blackduck-creds.json \
      -m ${manifest[@]} \
      -p ${PRODUCT} -v ${VERSION}
}

# If there's a product-specific manual Black Duck manifest, load that as well
manifest=( $(find "${WORKSPACE}/src" -maxdepth 8 -name ${PRODUCT}-black-duck-manifest.yaml) )
case ${#manifest[@]} in
  0) echo "No product-specific Black Duck manifest; skipping"
     ;;
  *) do-manual-manifest
     ;;
esac

# setup parent/sub project dependency if sub-project.json exists
if [ -f "${WORKSPACE}/build-tools/blackduck/${PRODUCT}/sub-project.json" ]; then
  "${WORKSPACE}/build-tools/blackduck/jenkins/detect-scan/add_subproject.py" \
    ${PRODUCT} \
    ${VERSION} \
    ${WORKSPACE}/build-tools/blackduck/${PRODUCT}/sub-project.json
fi
