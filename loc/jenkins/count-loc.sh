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
if [ -x "${WORKSPACE}/build-tools/loc/${PROD_NAME}/get_source.sh" ]; then
    "${WORKSPACE}/build-tools/loc/${PROD_NAME}/get_source.sh" ${PRODUCT} ${RELEASE} ${VERSION} ${BLD_NUM}
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
    TIMESTAMP=$(git show -s --format=%ci $SHA)

    # Back to the src directory
    popd

    echo "Syncing manifest $MANIFEST at $SHA"
    echo ================================
    repo init -u ssh://git@github.com/couchbase/build-manifests -b $SHA -g all -m $MANIFEST
    repo sync --jobs=8
    echo
fi

# May need to override this per-product?
find . -name .git -print0 | xargs -0 rm -rf
find . -name .repo -print0 | xargs -0 rm -rf

# Download cloc
mkdir -p "${WORKSPACE}/bin"
curl -Lo "${WORKSPACE}/bin/cloc" \
    https://github.com/AlDanial/cloc/releases/download/1.84/cloc-1.84.pl
chmod 755 "${WORKSPACE}/bin/cloc"
export PATH="${WORKSPACE}/bin:${PATH}"

echo @@@@@@@@@@@@@@@@@@@@@@@@@@@
echo "          REPORTS"
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@
echo

# Product-specific script for running desired reports
if [ -x "${WORKSPACE}/build-tools/loc/${PRODUCT}/run_cloc.sh" ]; then
    "${WORKSPACE}/build-tools/loc/${PRODUCT}/run_cloc.sh" ${RELEASE} "${TIMESTAMP}"
else
    cloc --quiet .
fi
