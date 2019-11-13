#!/bin/bash -ex

trigger() {
    cat <<EOF > "${WORKSPACE}/trigger.properties"
PRODUCT=${PRODUCT}
RELEASE=${RELEASE}
VERSION=${VERSION}
BLD_NUM=$1
EOF
    echo "Triggering scan for ${PRODUCT}-${RELEASE}-${VERSION}-$1"
    exit 0
}

# First check build database to see if this product/release/version is known
bld_num=$(
    curl -s "http://dbapi.build.couchbase.com:8000/v1/products/${PRODUCT}/releases/${RELEASE}/builds?filter=highest_build_num" | \
    jq -r ".build_num[0]"
)
if [ "${bld_num}" = "null" ]; then
    # Unknown product/release - probably a non-manifest product such as SDK,
    # so trigger the scan blindly
    trigger 9999
fi

# Check build database to see if this build has already been scanned
scanned=$(
    curl -s "http://dbapi.build.couchbase.com:8000/v1/products/${PRODUCT}/releases/${RELEASE}/versions/${VERSION}/builds/${bld_num}/metadata/blackduck_scan" | \
    jq -r ".data"
)
if [ "${scanned}" != "true" ]; then
    trigger ${bld_num}
fi

echo "Build ${PRODUCT}-${RELEASE}-${VERSION}-${bld_num} already scanned; exiting!"
