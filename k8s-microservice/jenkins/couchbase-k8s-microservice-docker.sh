#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# First build the images into the local cb-xxxxx organizations
${script_dir}/util/build-k8s-images.sh ${PRODUCT} ${VERSION} ${BLD_NUM} 1

# Figure out if this is the highest current version being built
highest_version=$(
    curl --silent http://dbapi.build.couchbase.com:8000/v1/products/${PRODUCT}/releases \
    | jq --raw-output '.releases[-1]'
)

# Compute tag(s) to push
version_build=${VERSION}-${BLD_NUM}
if [[ ${highest_version} = ${VERSION} && "${VERSION}" != *"-"* ]]; then
    tags="${version_build} latest"
else
    tags="${version_build}"
fi

# Now retag and push to internal and gitlab registries
pushd images
for product in *; do
    short_product=${product/couchbase-/}

    if product_in_rhcc "${PRODUCT}"
    then
        orgs="cb-vanilla cb-rhcc"
    else
        orgs="cb-vanilla"
    fi

    for org in $orgs; do
        local_org_image=${org}/${short_product}:${version_build}
        for registry in build-docker.couchbase.com registry.gitlab.com; do
            for tag in ${tags}; do
                remote_org_image=${registry}/${org}/${short_product}:${tag}

                docker tag ${local_org_image} ${remote_org_image}
                docker push ${remote_org_image}
                docker rmi ${remote_org_image}
            done
        done
        docker rmi ${local_org_image}
    done
done
