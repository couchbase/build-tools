# General utilities shell functions for k8s-microservice scripts

funclib_dir=$(dirname $(readlink -e -- "${BASH_SOURCE[0]}"))

# Succeeds if PRODUCT publishes images to REGISTRY ("dockerhub" or "rhcc"),
# ie. if PRODUCT is not listed under REGISTRY in products-without-images.json.
# A product listed under both has no images at all (eg. it only ships
# binaries, which the build uploads to latestbuilds).
function product_publishes_to {
    local PRODUCT=$1
    local REGISTRY=$2

    ! jq -e --arg p "${PRODUCT}" --arg r "${REGISTRY}" \
        '.[$r] // [] | index($p)' \
        "${funclib_dir}/products-without-images.json" > /dev/null
}

# Returns the external private pre-GA registry for a specific product.
function product_external_registry {
    local PRODUCT=$1

    # For now, just hardcode the one exception
    if [ "${PRODUCT}" = "couchbase-goldfish-nebula" ]; then
        echo "284614897128.dkr.ecr.us-east-2.amazonaws.com"
    else
        echo "ghcr.io"
    fi
}


# NOTE: this function assumes that VERSION == RELEASE; in particular it
# uses VERSION for the path on latestbuilds, which should be RELEASE.
# So don't use this function for products that use different values
# for VERSION and RELEASE.
# NOTE: this function also assumes that there is a project in the
# manifest with the exact name of the PRODUCT, and that that project
# is the one to tag.
function tag_release {
    if [ ${#} -ne 4 ]
    then
        error "expected [product] [version] [build_number] [tag], got ${@}"
    fi
    local PRODUCT=$1
    local VERSION=$2
    local BLD_NUM=$3
    local TAG=$4

    if [ "${PRODUCT}" = "couchbase-elasticsearch-connector" ]; then
        status "Opting out of tagging ${PRODUCT}"
        return
    fi

    curl --fail -LO http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${VERSION}/${BLD_NUM}/${PRODUCT}-${VERSION}-${BLD_NUM}-manifest.xml

    REVISION=$(xmllint --xpath "string(//project[@name=\"${PRODUCT}\"]/@revision)" ${PRODUCT}-${VERSION}-${BLD_NUM}-manifest.xml)
    if [ -z "${REVISION}" ]; then
        warn "Project named '${PRODUCT}' not found in manifest; skipping auto-tagging"
        return
    fi

    git clone "ssh://review.couchbase.org:29418/${PRODUCT}.git"

    pushd "${PRODUCT}"
    if [ "${REVISION}" = "" ]
    then
        error "Got empty revision from manifest, couldn't tag release"
    elif ! test "$(git cat-file -t ${REVISION})" = "commit"
    then
        error "Expected to find a commit, found a $(git cat-file -t ${REVISION}) instead"
    else
        if [ $(git tag -l "${TAG}") ]
        then
            status "Tag ${TAG} already exists, please ensure that is correct"
        else
            git tag -a "${TAG}" "${REVISION}" -m "Release ${TAG}"
            git push "ssh://review.couchbase.org:29418/${PRODUCT}.git" ${VERSION}
        fi
    fi
    popd
}
