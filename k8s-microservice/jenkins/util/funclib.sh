# General utilities shell functions for k8s-microservice scripts

function product_in_rhcc {
    local PRODUCT=$1

    if [ "${PRODUCT}" = "couchbase-service-broker" -o "${PRODUCT}" = "couchbase-observability-stack" ]; then
        return 1
    fi

    return 0
}

# NOTE: this function assumes that VERSION == RELEASE; in particular it
# uses VERSION for the path on latestbuilds, which should be RELEASE.
# So don't use this function for products that use different values
# for VERSION and RELEASE.
# NOTE: this function also assumes that there is a project in the
# manifest with the exact name of the PRODUCT, and that that project
# is the one to tag.
function tag_release {
    if [ ${#} -ne 3 ]
    then
        error "expected [product] [version] [build_number], got ${@}"
    fi
    local PRODUCT=$1
    local VERSION=$2
    local BLD_NUM=$3

    curl --fail -LO http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}/${PRODUCT}-${VERSION}-${BLD_NUM}-manifest.xml

    REVISION=$(xmllint --xpath "string(//project[@name=\"${PRODUCT}\"]/@revision)" ${PRODUCT}-${VERSION}-${BLD_NUM}-manifest.xml)

    git clone "ssh://review.couchbase.org:29418/${PRODUCT}.git"

    pushd "${PRODUCT}"
    if [ "${REVISION}" = "" ]
    then
        error "Got empty revision from manifest, couldn't tag release"
    elif ! test "$(git cat-file -t ${REVISION})" = "commit"
    then
        error "Expected to find a commit, found a $(git cat-file -t ${REVISION}) instead"
    else
        if git tag | grep "${VERSION}" &>/dev/null
        then
            error "Tag ${VERSION} already exists, please investigate ($(git rev-parse -n1 ${VERSION}))"
        else
            git tag -a "${VERSION}" "${REVISION}" -m "Version ${VERSION}"
            git push "ssh://review.couchbase.org:29418/${PRODUCT}.git" ${VERSION}
        fi
    fi
    popd
}
