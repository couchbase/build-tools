#!/bin/bash -ex

PROD_DIR="${WORKSPACE}/build-tools/blackduck/${PRODUCT}"
SCRIPT_DIR="${WORKSPACE}/build-tools/blackduck/jenkins/generate-reports"

# Required to push back to git
GIT_DIR="${WORKSPACE}/product-metadata/${PRODUCT}/blackduck/${VERSION}"
git clone ssh://git@github.com/couchbase/product-metadata.git product-metadata
mkdir -p ${GIT_DIR}

# Install required Blackduck modules

cd ${SCRIPT_DIR}
python3 -m venv .venv
source .venv/bin/activate
pip3 install --upgrade pip
pip3 install -r requirements.txt

OUTPUT_DIR=${WORKSPACE}/output
mkdir -p ${OUTPUT_DIR}

# Call Black Duck API to generate output files
set +e
./download-reports.py \
    ${PRODUCT} ${VERSION} ${BLD_NUM} \
    -c ~/.ssh/blackduck-creds.json \
    --output-dir ${OUTPUT_DIR}
retval=$?
set -e

# Clean up after the Hub REST API
rm -f .restconfig.json

# Copy out components and notices to product-metadata
cp ${OUTPUT_DIR}/*-components.csv ${GIT_DIR}/components.csv
cp ${OUTPUT_DIR}/*-notices.txt ${GIT_DIR}/notices.txt

pushd ${GIT_DIR}

# Delete Phase and Distribution lines from notices.txt, and insert
# product-specific additional information (if any)
if [ -e ${PROD_DIR}/additional-notices.txt ]; then
    ADD_FILE=${PROD_DIR}/additional-notices.txt
else
    ADD_FILE=${SCRIPT_DIR}/empty-file.txt
fi

sed -i -e "
    1,10 {
        /^Phase: / {
            r ${ADD_FILE}
            d
        }
        /^Distribution: / d
    }
" notices.txt

# Push back to GitHub
git add .
git config --global push.default simple
git diff --quiet && git diff --staged --quiet || git commit \
    -m "Updated Black Duck metadata for ${PRODUCT} ${VERSION}-${BLD_NUM}" \
    --author='Couchbase Build Team <build-team@couchbase.com>'
git push
popd

exit $retval
