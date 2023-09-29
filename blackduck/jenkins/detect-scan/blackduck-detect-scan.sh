#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}
PRODUCT_BASENAME=$(basename $PRODUCT_PATH)
PROD_DIR="${WORKSPACE}/build-tools/blackduck/${PRODUCT_PATH}"
DETECT_SCRIPT_DIR="${WORKSPACE}/build-tools/blackduck/jenkins/detect-scan"
SCAN_CONFIG="${PROD_DIR}/scan-config.json"

# Arrange for cbdep to be on the PATH for everyone
CBDEP_DIR="${WORKSPACE}/extra/cbdep"
mkdir -p "${CBDEP_DIR}"
if [ ! -x "${CBDEP_DIR}/cbdep" ]; then
    curl -L -o "${CBDEP_DIR}/cbdep" http://downloads.build.couchbase.com/cbdep/cbdep.linux
    chmod 755 "${CBDEP_DIR}/cbdep"
fi
export PATH="${CBDEP_DIR}:${PATH}"

# Disable analytics
# https://community.synopsys.com/s/article/How-to-disable-Phone-Home-when-running-Detect
export SYNOPSYS_SKIP_PHONE_HOME=true

# Extract config parameters from scan-config.json, if available
if [ -e "${SCAN_CONFIG}" ]; then
    KEEP_GIT=$(jq --arg VERSION ${VERSION} '.versions[$VERSION].keep_git' "${SCAN_CONFIG}")
fi

# Reset src directory and cd into it
SRC_DIR="${WORKSPACE}/src"
mkdir -p "${SRC_DIR}"
rm -rf "${SRC_DIR}"/[A-z]*
cd "${SRC_DIR}"

# Prep a virtualenv - we need this below if any black duck manifests are found
# and also for installing packages via pip where required e.g. sdk-ruby
venv="${WORKSPACE}/.venv"
if [ ! -d "${venv}" ]; then
  python3 -m venv "${venv}"
fi
source "${venv}/bin/activate"

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
    repo sync --jobs=8
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

# The Azure people are always causing problems. Now v64.2.0 is too large
# to be considered a module, causing sum.golang.org to throw an error.
# Since we don't know when something may indirectly refer to this
# version, safest best is to just skip the checksum DB for this module.
export GONOSUMDB=${GONOSUMDB},github.com/Azure/azure-sdk-for-go

# Normally remove .git directories
if [ "${KEEP_GIT}" != true ]; then
    find . -name .git -print0 | xargs -0 rm -rf
fi
find . -name .repo -print0 | xargs -0 rm -rf

# Find any Black Duck manifests
manifest=( $(find "${WORKSPACE}" -maxdepth 9 -name ${PRODUCT_BASENAME}-black-duck-manifest.yaml) )
if [ "${#manifest[@]}" != "0" ]; then
  echo "Black Duck manifest(s) found; prepping python environment"

  pip3 install -r "${DETECT_SCRIPT_DIR}/manual-manifest-requirements.txt"

  echo "Pruning any source directories referenced by Black Duck manifests"
  "${DETECT_SCRIPT_DIR}/prune-from-manual-manifest" -d -m ${manifest[@]}
fi

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
python3 -u "${DETECT_SCRIPT_DIR}/run-scanner" \
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

# If there's a product-specific manual Black Duck manifest, load that as well
if [ "${#manifest[@]}" != "0" ]; then
  echo "Loading product-specific Black Duck manifests: ${manifest[@]}"
  "${DETECT_SCRIPT_DIR}/update-manual-manifest" -d \
      -c ~/.ssh/blackduck-creds.json \
      -m ${manifest[@]} \
      -p ${PRODUCT} -v ${VERSION}
else
  echo "No product-specific Black Duck manifests; skipping"
fi

# setup parent/sub project dependency if sub-project.json exists
if [ -f "${PROD_DIR}/sub-project.json" ]; then
  "${DETECT_SCRIPT_DIR}/add_subproject.py" \
    ${PRODUCT} \
    ${VERSION} \
    ${PROD_DIR}/sub-project.json
fi
