#!/bin/bash -e

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM
chk_set LATEST

# If PUBLIC_TAG is non-empty in the environment, use that; otherwise
# default to VERSION. (Usually the public tag for a release is the same
# as the version number, but sometimes we'll do things like 1.2.0-beta.)
if [ -z "${PUBLIC_TAG}" ]; then
    public_tag=${VERSION}
    suffix=""
else
    public_tag=${PUBLIC_TAG}
    suffix=${PUBLIC_TAG/$VERSION-/}
fi

# Normally we use the OpenShift REBUILD number "1", since this is presumed
# to be the first release of a given version. However we allow overriding
# it for emergencies, like when the initial upload fails RHCC scan validation.
OS_BUILD=${OS_BUILD-1}
if ${LATEST}; then
    LATEST_ARG="-l"
fi

# couchbase-operator has two "sub-projects", couchbase-admission-controller
# and couchbase-operator-certification. Those exist only as Docker images.
# Go ahead and release those images now if we're doing a couchbase-operator
# release, and then fall through to continue releasing couchbase-operator.
case "${PRODUCT}" in
    couchbase-admission-controller|couchbase-operator-certification)
        echo "${PRODUCT} is released as side-effect of couchbase-operator; quitting"
        exit 1
        ;;
    couchbase-operator)
        header Releasing couchbase-admission-controller...
        ${script_dir}/util/publish-k8s-images.sh \
            -p couchbase-admission-controller -i ${VERSION}-${BLD_NUM} \
            -t ${public_tag} -o ${OS_BUILD} ${LATEST_ARG}
        header Releasing couchbase-operator-certification...
        ${script_dir}/util/publish-k8s-images.sh \
            -p couchbase-operator-certification -i ${VERSION}-${BLD_NUM} \
            -t ${public_tag} -o ${OS_BUILD} ${LATEST_ARG}
        ;;
esac

${script_dir}/util/publish-k8s-images.sh \
    -p ${PRODUCT} -i ${VERSION}-${BLD_NUM} -t ${public_tag} \
    -o ${OS_BUILD} ${LATEST_ARG}


# For convenience, save a trigger.properties for update_manifest_released
# and release_binaries_to_s3.
# Do this after the above check so that we will only propose changes for
# images that have corresponding manifests and artifacts.
# release_binaries_to_s3 uses PRODUCT while update_manifest_released uses
# PRODUCT_PATH, but for top-level products those are the same thing.
cat <<EOF > trigger.properties
PRODUCT_PATH=${PRODUCT}
PRODUCT=${PRODUCT}
RELEASE=${VERSION}
VERSION=${VERSION}
BLD_NUM=${BLD_NUM}
SUFFIX=${suffix}
APPROVAL_ISSUE=${APPROVAL_ISSUE}
EOF

# Add git tag for release.
# As a heuristic special case, if OS_BUILD is not 1 we assume this is
# an emergency re-release of RHCC, and therefore git tagging was
# probably already done, so skip it.
if [ "${OS_BUILD}" = "1" ]; then
    tag_release "${PRODUCT}" "${VERSION}" "${BLD_NUM}" "${public_tag}"
fi
