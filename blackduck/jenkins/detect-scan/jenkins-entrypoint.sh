#!/bin/bash -e

# Main script for https://server.jenkins.couchbase.com/job/blackduck-detect-scan
# Runs all sub-jobs and updates build database

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. ${SCRIPT_DIR}/../../../utilities/shell-utils.sh

# Error-checks for interactive testing
chk_set WORKSPACE
chk_set PRODUCT
chk_set RELEASE
chk_set VERSION
chk_set BLD_NUM
chk_set DRY_RUN

PRODUCT_PATH=${PRODUCT/::/\/}

# If testing locally, set this before running script
export SKIP_GIT_PUSH=${SKIP_GIT_PUSH-false}

# Set up this call to run whether the following steps succeed or fail
# This will run at the end of the script no matter what, and update the
# build database according to the `success` value
update_builddb() {

  # Exit early if this product isn't manifest-driven
  if [ ! -d "${WORKSPACE}/build-manifests/${PRODUCT_PATH}" ]; then
    header "Product ${PRODUCT} is not manifest-driven, so not updating build database"
    exit
  fi

  builddb_doc="${PRODUCT}-${VERSION}-${BLD_NUM}"
  header "Updating Build Database metadata for ${builddb_doc}: blackduck_scan=${scan_status}"

  # Sometimes load_build_database won't finish before the BD scan does, so
  # give it a couple minutes to catch up
  count=0
  while true; do
    curl_status=$( \
      curl -o /dev/null -w "%{http_code}" -s \
        -d '{"blackduck_scan": "'${scan_status}'"}' \
        -X POST -H "Content-Type: application/json" \
        https://dbapi.build.couchbase.com/v1/builds/${builddb_doc}/metadata \
    )
    if [ "${curl_status}" == "200" ]; then
      echo "Build Database updated successfully."
      break
    fi

    let "count=$count+1"
    if [ "${count}" -ge 10 ]; then
      echo "Build not available in Build Database after 10 tries; giving up."
      break
    fi

    echo "${PRODUCT}-${VERSION}-${BLD_NUM} is not in the build database yet, waiting..."
    sleep 10
  done
}
trap update_builddb EXIT

# Default status is "fail"; will be updated to "pass" if all steps pass
scan_status=fail

cd "${WORKSPACE}"
header "Performing primary Black Duck scan and manual-manifest update..."
./build-tools/blackduck/jenkins/detect-scan/blackduck-detect-scan.sh

# For dry-runs, we want to skip the remaining steps, and also skip updating the
# Build Database
if $DRY_RUN; then
    header "Dry run - not generating reports"
    trap 'echo Done.' EXIT
    exit
fi

header "Generating NOTICES and other reports"
./build-tools/blackduck/jenkins/generate-reports/generate-reports.sh

header "Checking for 'suspect' licenses"
./build-tools/blackduck/jenkins/check-licences/blackduck-check-licenses.sh

header "Producing vulnerability report"
./build-tools/blackduck/jenkins/vulnerability-report/blackduck-vulnerability-report.sh

scan_status=pass
