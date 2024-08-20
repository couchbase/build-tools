#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

# Basic help information
function show_help {
    set +x
    echo "Usage: $0 <options>"
    echo "Options:"
    echo "  -p : Product to build (e.g. couchbase-server) (Required)"
    echo "  -v : Version of product to use (e.g. 5.1.0) (Required)"
    echo "  -b : Build number to use (eg. 1234) (Required with -l)"
    echo "  -s : Build from staging repository (Optional, defaults to false)"
    echo "  -l : Pull build from latestbuilds, rather than download from S3"
    echo "       (Only works with most recent Server/SGW versions)"
    echo "  -f : Force (don't use Docker build cache)"
    echo "  -n : Dry run (don't push to docker registries)"
    exit 0
}

function multiarch() {
    case "${PRODUCT}" in
        couchbase-server)
            version_lt ${VERSION} 7.1.3 && return 1
            ;;
        sync-gateway)
            version_lt ${VERSION} 3.0.4 && return 1
            ;;
    esac
    return 0
}

STAGING=""
DRYRUN=""
FROM_LATESTBUILDS="false"
FORCE="false"

# Parse options and ensure required ones are there
while getopts :p:v:b:slfnh opt; do
    case ${opt} in
        p) PRODUCT="$OPTARG"
           ;;
        v) VERSION="$OPTARG"
           ;;
        b) BLD_NUM="$OPTARG"
           ;;
        s) STAGING="-staging"
           ;;
        l) FROM_LATESTBUILDS="true"
           ;;
        f) FORCE="true"
           ;;
        n) DRYRUN="yes"
           ;;
        h) show_help
           ;;
        \?) # Unrecognized option, show help
            echo -e \\n"Invalid option: ${OPTARG}" 1>&2
            show_help
    esac
done

if [[ -z "$PRODUCT" ]]; then
    echo "Product name (-p) is required"
    exit 1
fi

if [[ -z "$VERSION" ]]; then
    echo "Version of product (-v) is required"
    exit 1
fi

if ${FROM_LATESTBUILDS}; then

    if [[ -z "$BLD_NUM" ]]; then
        echo "Build number of product (-b) is required"
        exit 1
    fi

    if [[ ${PRODUCT} == "couchbase-server" && $BLD_NUM -lt 10 ]]; then
        echo "Please use complete internal build number, not ${BLD_NUM}"
        exit 1
    fi
fi

# Download redhat-openshift repository containing Dockerfiles
if [[ ! -d redhat-openshift ]]; then
    git clone https://github.com/couchbase-partners/redhat-openshift
else
    pushd redhat-openshift
    git fetch --all && git reset --hard origin/master
    popd
fi

# Enter product directory
cd redhat-openshift/${PRODUCT}

# Use new UBI-based Dockerfile for Server 7.x or later, or SGW 3.x or later
if [[ ${PRODUCT} == "couchbase-server" ]]; then
    if [[ ${VERSION} =~ ^6.* ]]; then
        echo "Using legacy Dockerfile.6.x"
        DOCKERFILE=Dockerfile.old
    else
        DOCKERFILE=Dockerfile
    fi
elif [[ ${PRODUCT} == "sync-gateway" ]]; then
    if multiarch; then
        echo "Using multiarch Dockerfile.multiarch"
        DOCKERFILE=Dockerfile.multiarch
    elif [[ ${VERSION} =~ ^2.* ]]; then
        echo "Using legacy Dockerfile.2.x"
        DOCKERFILE=Dockerfile.2.x
    else
        echo "Using legacy Dockerfile.x64"
        DOCKERFILE=Dockerfile.x64
    fi
fi

# Determine image name per project - these are always uploaded to GHCR,
# so the build server should have push access there
if [[ ${PRODUCT} == "couchbase-server" ]]; then
    INTERNAL_IMAGE_NAME=cb-rhcc/server
else
    INTERNAL_IMAGE_NAME=cb-rhcc/sync-gateway
fi

BUILD_ARGS="--build-arg PROD_VERSION=${VERSION} --build-arg STAGING=${STAGING}"

if ${FROM_LATESTBUILDS}; then
    # When building from latestbuilds, set RELEASE_BASE_URL and PROD_VERSION
    # Docker build arguments. The specific URL also varies between
    # couchbase-server and sync-gateway.
    BUILD_ARGS+=" --build-arg RELEASE_BASE_URL="
    BUILD_ARGS+="https://latestbuilds.service.couchbase.com/builds/latestbuilds"
    if [[ ${PRODUCT} == "couchbase-server" ]]; then
        BUILD_ARGS+="/${PRODUCT}/zz-versions"
    else
        BUILD_ARGS+="/sync_gateway"
    fi
    BUILD_ARGS+="/${VERSION}/${BLD_NUM}"
    BUILD_ARGS+=" --build-arg PROD_VERSION=${VERSION}-${BLD_NUM}"

    TAG_SUFFIX=${BLD_NUM}
else
    # Use -rel or -staging suffixes for post-GA builds - this corresponds to
    # the tags rhcc-certify-and-publish.sh expects to find for rebuilds
    if [[ -z "${STAGING}" ]]; then
        TAG_SUFFIX="rel"
    else
        TAG_SUFFIX="staging"
    fi
fi

if ${FORCE}; then
    BUILD_ARGS+=" --no-cache"
fi

# Compute array of image names
IMAGES=()
for registry in ghcr.io build-docker.couchbase.com; do
    IMAGES+=(${registry}/${INTERNAL_IMAGE_NAME}:${VERSION}-${TAG_SUFFIX})
done

# Build and push/load images
if [[ "${DRYRUN}" = "yes" && multiarch ]]; then
    # For multiarch dry run, we build each architecture's image
    # individually so we can load them into the local image store for
    # testing. To do this we also need to append "-${arch}" to each
    # image name.
    for arch in amd64 arm64; do
        ARCHIMAGES=("${IMAGES[@]/%/-${arch}}")

        echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        echo Building ${ARCHIMAGES[@]}
        echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        docker buildx build --pull --platform linux/${arch} --load \
            ${BUILD_ARGS} -f ${DOCKERFILE} ${ARCHIMAGES[@]/#/-t } .
    done
else
    if multiarch; then
        PLATFORMS="linux/amd64,linux/arm64"
    else
        PLATFORMS="linux/amd64"
    fi
    echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    echo Building and Pushing ${IMAGES[@]}
    echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    docker buildx build --pull --platform ${PLATFORMS} --push \
        ${BUILD_ARGS} -f ${DOCKERFILE} ${IMAGES[@]/#/-t } .
fi
