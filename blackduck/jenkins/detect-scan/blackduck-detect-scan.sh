#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}
PRODUCT_BASENAME=$(basename $PRODUCT_PATH)
PROD_DIR="${WORKSPACE}/build-tools/blackduck/${PRODUCT_PATH}"
DETECT_SCRIPT_DIR="${WORKSPACE}/build-tools/blackduck/jenkins/detect-scan"
GET_ADDITIONAL_SOURCE_SCRIPT="${PROD_DIR}/get_additional_source.sh"
GET_SOURCE_SCRIPT="${PROD_DIR}/get_source.sh"
SCAN_CONFIG="${PROD_DIR}/scan-config.json"
DETECT_CONFIG="${PROD_DIR}/detect-config.json"
ENV_FILE="${PROD_DIR}/.env"
KEEP_GIT=false

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source ${SCRIPT_DIR}/../../../utilities/shell-utils.sh

# detect-config.json is required, so check for it right away
if [ ! -e "${DETECT_CONFIG}" ]; then
  error "${DETECT_CONFIG} not found!"
fi

# run_script executes a script by sourcing it (passing any args) in a subshell.
# We capture its exports and dump them to file before the subshell closes, and
# source that file when execution resumes. This results in any environmental
# changes made by the scripts being available to the following steps and the
# scan itself
function run_script() {
  local script=$1
  shift
  (
    source "${script}" "$@"
    set +x
    printf "$(export -p | sed 's/declare -x/declare -gx/g')\n" >> "${ENV_FILE}"
    set -x
  )
  source "${ENV_FILE}" >&/dev/null
}

# Tidy up any .env files which were created by run_script
function clean_up() {
  rm  -f "${ENV_FILE}"
}
trap clean_up EXIT

# Disable analytics
# https://documentation.blackduck.com/bundle/detect/page/troubleshooting/usage-metrics.html
export BLACKDUCK_SKIP_PHONE_HOME=true

# Reset src directory and cd into it
SRC_DIR="${WORKSPACE}/src"
mkdir -p "${SRC_DIR}"
rm -rf "${SRC_DIR}"/[A-z]*
cd "${SRC_DIR}"

# Prep a virtualenv for use by project scripts, eg.
# couchbase-sdk-columnar-python/get_source.sh.
# Some day maybe those scripts should handle their own, maybe if they need
# control over the python version...
venv="${PROD_DIR}/.venv"
rm -rf "${venv}"
uv venv --python 3.11 --python-preference only-managed "${venv}"
source "${venv}/bin/activate"
python -m ensurepip --upgrade --default-pip

if [ -f "${GET_SOURCE_SCRIPT}" ]; then
  # If the product doesn't have a bespoke get_source.sh, then look up
  # the build manifest and sync that
  run_script "${GET_SOURCE_SCRIPT}" ${PRODUCT} ${RELEASE} ${VERSION} ${BLD_NUM}

  # Extract KEEP_GIT parameters from scan-config.json, if available. If
  # there's a get_source.sh, there should be a scan-config.json also;
  # and if there isn't a get_source.sh, there shouldn't be a
  # scan-config.json.
  if [ -e "${SCAN_CONFIG}" ]; then
    KEEP_GIT=$(jq --arg VERSION ${VERSION} '.versions[$VERSION].keep_git' "${SCAN_CONFIG}")
  fi

else

  # repo sync the build manifest
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
  repo_init -u ssh://git@github.com/couchbase/build-manifests -b $SHA -g all -m $MANIFEST
  repo sync --jobs=8
  repo manifest -r > manifest.xml
  echo

  # Check detect-config.json for keep_git - only do this for
  # manifest-driven runs (ie, without get_source.sh) since
  # non-manifest-driven runs utilize `scan-config.json` for this purpose
  KEEP_GIT=$(jq '.cb_opts.keep_git' "${DETECT_CONFIG}")
fi

# Product-specific script for getting additional sources
if [ -f "${GET_ADDITIONAL_SOURCE_SCRIPT}" ]; then
  run_script "${GET_ADDITIONAL_SOURCE_SCRIPT}" ${RELEASE} ${VERSION} ${BLD_NUM}
fi

# The Azure people are always causing problems. Now v64.2.0 is too large
# to be considered a module, causing sum.golang.org to throw an error.
# Since we don't know when something may indirectly refer to this
# version, safest best is to just skip the checksum DB for this module.
export GONOSUMDB=${GONOSUMDB},github.com/Azure/azure-sdk-for-go

# Normally remove .git and .repo directories
if [ "${KEEP_GIT}" != true ]; then
  find . -name .git -print0 | xargs -0 rm -rf
  rm -rf .repo
else
  # If not removing .git and .repo, at least remove .repo/repo and
  # .repo/manifest* so they don't get scanned
  rm -rf .repo/repo .repo/manifest*
fi

# Prune source that we will "manually" enter into Black Duck
echo "Pruning any source directories referenced by Black Duck manifests"
uv run --project "${DETECT_SCRIPT_DIR}" --quiet \
  "${DETECT_SCRIPT_DIR}/update-manual-manifest.py" -d \
    -p ${PRODUCT} -v ${VERSION} --operation prune --src-root "${WORKSPACE}"

# Product-specific script for pruning unwanted sources
if [ -x "${PROD_DIR}/prune_source.sh" ]; then
  "${PROD_DIR}/prune_source.sh" \
      ${RELEASE} ${VERSION} ${BLD_NUM} \
      "${PROD_DIR}"
fi

# Product-specific config for Synopsys Detect
CONFIG_ARG="-c ${DETECT_CONFIG}"

# If doing dry-run, clean out any old archives
if [ "x${DRY_RUN}" = "xtrue" ]; then
  export DRY_RUN_ARG="-n"
  rm -rf ~/blackduck/runs/*
fi

# Invoke scan script
uv run --project "${DETECT_SCRIPT_DIR}" --quiet \
  python -u "${DETECT_SCRIPT_DIR}/run-scanner" \
    ${DRY_RUN_ARG} \
    ${CONFIG_ARG} \
    --python-venv ${venv} \
    --credentials ~/.ssh/blackduck-creds.json \
    --pdf

# Copy up dry-run archives
if [ "x${DRY_RUN}" = "xtrue" ]; then
  echo Copying dryrun archives...
  cp ~/blackduck/runs/detect-run*.zip ${WORKSPACE}
  # Don't go on to add manual entries
  exit
fi

# If there's product-specific manual Black Duck manifests, load that as well
echo "Loading product-specific Black Duck manifests"
uv run --project "${DETECT_SCRIPT_DIR}" --quiet \
  "${DETECT_SCRIPT_DIR}/update-manual-manifest.py" -d \
    --credentials ~/.ssh/blackduck-creds.json \
    --operation update --src-root "${WORKSPACE}" \
    -p ${PRODUCT} -v ${VERSION}

# setup parent/sub project dependency if sub-project.json exists
if [ -f "${PROD_DIR}/sub-project.json" ]; then
  uv run --project "${DETECT_SCRIPT_DIR}" --quiet \
    "${DETECT_SCRIPT_DIR}/add_subproject.py" \
      ${PRODUCT} \
      ${VERSION} \
      ${PROD_DIR}/sub-project.json
fi
