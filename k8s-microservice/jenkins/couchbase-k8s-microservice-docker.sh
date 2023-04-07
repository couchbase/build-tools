#!/bin/bash -ex

internal_repo=build-docker.couchbase.com

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# First build the images into the local cb-xxxxx organizations
OS_BUILD=${OS_BUILD-1}
${script_dir}/util/build-k8s-images.sh \
    -p ${PRODUCT} -v ${VERSION} -b ${BLD_NUM} -o ${OS_BUILD}

# Figure out if this is the highest current version being built
highest_version=$(
    curl --silent http://dbapi.build.couchbase.com:8000/v1/products/${PRODUCT}/releases \
    | jq --raw-output '[ .[][] | select(contains("-")|not) ] | .[-1]'
)

# Compute tag(s) to push
version_build=${VERSION}-${BLD_NUM}
if [[ ${highest_version} = ${VERSION} && "${VERSION}" != *"-"* ]]; then
    tags="${version_build} latest"
else
    tags="${version_build}"
fi

# Now retag and push to internal and GHCR registries
pushd images
for product in *; do
    short_product=${product/couchbase-/}

    if product_in_rhcc "${PRODUCT}"
    then
        orgs="cb-vanilla cb-rhcc"
    else
        orgs="cb-vanilla"
    fi

    if [ "${RHCC_ONLY}" = "true" ]; then
        orgs=${orgs/cb-vanilla/}
    fi

    for org in $orgs; do
        internal_org_image=${internal_repo}/${org}/${short_product}:${version_build}
        for registry in build-docker.couchbase.com ghcr.io; do
            for tag in ${tags}; do
                remote_org_image=${registry}/${org}/${short_product}:${tag}
                skopeo copy --authfile /home/couchbase/.docker/config.json --all \
                    docker://${internal_org_image} docker://${remote_org_image}
            done
        done
    done
done
