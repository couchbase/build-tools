#!/bin/bash -ex

PRODUCT_PATH=${PRODUCT/::/\/}
PROD_DIR="${WORKSPACE}/build-tools/blackduck/${PRODUCT_PATH}"
SCRIPT_DIR="${WORKSPACE}/build-tools/blackduck/jenkins/generate-reports"

# Required to push back to git
GIT_DIR="${WORKSPACE}/product-metadata/${PRODUCT_PATH}/blackduck/${VERSION}"
"${WORKSPACE}/build-tools/utilities/clean_git_clone" ssh://git@github.com/couchbase/product-metadata.git product-metadata
mkdir -p ${GIT_DIR}

OUTPUT_DIR=${WORKSPACE}/output
mkdir -p ${OUTPUT_DIR}

# Call Black Duck API to generate output files
cd ${SCRIPT_DIR}
set +e
uv run download-reports.py \
    ${PRODUCT} ${VERSION} ${BLD_NUM} \
    -c ~/.ssh/blackduck-creds.json \
    --output-dir ${OUTPUT_DIR}
retval=$?
set -e

# Clean up after the Hub REST API
rm -f .restconfig.json

# Copy out components and notices to product-metadata
cp ${OUTPUT_DIR}/*-notices.txt ${GIT_DIR}/notices.txt
cp ${OUTPUT_DIR}/components.csv ${GIT_DIR}/components.csv

pushd ${GIT_DIR}

# Check for the Stupid License and fail if it's in there.
# Note: so far, every component we use that's under the Stupid License
# is also licensed under something Not Stupid such as MIT. So if this
# shows up, go into the Black Duck Hub and edit the license for this
# component so that only the Not Stupid license remains. If we ever
# hit a component that is ONLY licensed under the Stupid License,
# we'll need to figure out what to do then.
wtfpls=$(grep -i 'what the f.ck' components.csv|cut -d, -f4-5)
[ -z "${wtfpls}" ] || {
    cat <<EOF

--------------------------
ERROR: WTFPL license found
--------------------------

The following components are licensed under WTFPL. Please correct in
Black Duck Hub.

--------------------------
$(grep -i 'what the f.ck' components.csv)
--------------------------

This script will now terminate to avoid committing offensive language to
our GitHub repositories.

EOF
    exit 5
}

# Insert any extra notices files.
mkdir -p "${WORKSPACE}/temp"
ADDITIONAL_NOTICES="${WORKSPACE}/temp/additional-notices.txt"
rm -f "${ADDITIONAL_NOTICES}"
touch "${ADDITIONAL_NOTICES}"
if [ -e ${PROD_DIR}/additional-notices.txt ]; then
    cat "${PROD_DIR}/additional-notices.txt" >> "${ADDITIONAL_NOTICES}"
fi
for file in $(find ${WORKSPACE}/src -type f -name ${PRODUCT}-additional-notices.txt); do
    cat "${file}" >> "${ADDITIONAL_NOTICES}"
done

# Delete Phase and Distribution lines from notices.txt, and insert
# product-specific additional information (if any)
sed -i -e "
    1,10 {
        /^Phase: / {
            r ${ADDITIONAL_NOTICES}
            d
        }
        /^Distribution: / d
    }
" notices.txt

# Push back to GitHub
git add .
git config push.default simple
git diff --quiet && git diff --staged --quiet || git commit \
    -m "Updated Black Duck metadata for ${PRODUCT} ${VERSION}-${BLD_NUM}" \
    --author='Couchbase Build Team <build-team@couchbase.com>'
if ! $SKIP_GIT_PUSH; then
    git push
fi
popd

exit $retval
