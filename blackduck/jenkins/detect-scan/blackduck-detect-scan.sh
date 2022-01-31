#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}
PROD_NAME=$(basename $PRODUCT_PATH)
PROD_DIR="${WORKSPACE}/build-tools/blackduck/${PROD_NAME}"
SCAN_CONFIG="${PROD_DIR}/scan-config.json"

# Extract config parameters from scan-config.json, if available
if [ -e "${SCAN_CONFIG}" ]; then
    KEEP_GIT=$(jq --arg VERSION ${VERSION} '.versions[$VERSION].keep_git' "${SCAN_CONFIG}")
fi

# Reset src directory and cd into it
SRC_DIR="${WORKSPACE}/src"
rm -rf "${SRC_DIR}"
mkdir "${SRC_DIR}"
cd "${SRC_DIR}"

# If the product doesn't have a bespoke get_source.sh, then look up the
# build manifest and sync that
if [ -x "${PROD_DIR}/get_source.sh" ]; then
    "${PROD_DIR}/get_source.sh" ${PRODUCT} ${RELEASE} ${VERSION} ${BLD_NUM}
else
    pushd "${WORKSPACE}"

    # Sync build-manifests
    if [ ! -e build-manifests ]; then
        git clone ssh://git@github.com/couchbase/build-manifests
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
    repo init -u ssh://git@github.com/couchbase/build-manifests -b $SHA -g all -m $MANIFEST
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
if [ -x "${PROD_DIR}/get_additional_source.sh" ]; then
  "${PROD_DIR}/get_additional_source.sh" ${RELEASE} ${VERSION} ${BLD_NUM}
fi

# Product-specific environment overrides
if [ -x "${PROD_DIR}/scan-environment.sh" ]; then
  SCAN_ENV=$("${PROD_DIR}/scan-environment.sh")
  if [ $? != 0 ]; then
    echo "Error setting override environment! Output was"
    echo "${SCAN_ENV}"
    exit 3
  fi
  eval "${SCAN_ENV}"
  echo "Environment after injection from scan-environment.sh:"
  env
fi

# Normally remove .git directories
if [ "${KEEP_GIT}" != true ]; then
    find . -name .git -print0 | xargs -0 rm -rf
fi
find . -name .repo -print0 | xargs -0 rm -rf

# Product-specific script for pruning unwanted sources
if [ -x "${PROD_DIR}/prune_source.sh" ]; then
  "${PROD_DIR}/prune_source.sh" \
      ${RELEASE} ${VERSION} ${BLD_NUM} \
      "${PROD_DIR}"
fi

# Product-specific config for Synopsys Detect
if [ -e "${PROD_DIR}/detect-config.json" ]; then
  CONFIG_ARG="-c ${PROD_DIR}/detect-config.json"
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
manifest=( $(find "${WORKSPACE}" -maxdepth 9 -name ${PRODUCT}-black-duck-manifest.yaml) )
case ${#manifest[@]} in
  0) echo "No product-specific Black Duck manifest; skipping"
     ;;
  *) do-manual-manifest
     ;;
esac

# setup parent/sub project dependency if sub-project.json exists
if [ -f "${PROD_DIR}/sub-project.json" ]; then
  "${WORKSPACE}/build-tools/blackduck/jenkins/detect-scan/add_subproject.py" \
    ${PRODUCT} \
    ${VERSION} \
    ${PROD_DIR}/sub-project.json
fi
