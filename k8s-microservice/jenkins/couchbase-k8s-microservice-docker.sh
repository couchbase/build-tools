#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh

chk_set PRODUCT
chk_set VERSION
chk_set BLD_NUM

# First build the images into the local cb-xxxxx organizations
${script_dir}/util/build-k8s-images.sh ${PRODUCT} ${VERSION} ${BLD_NUM} 1

# Now retag and push to internal and gitlab registries
pushd images
for product in *; do
    short_product=${product/couchbase-/}
    tag=${VERSION}-${BLD_NUM}
    for org in cb-vanilla cb-rhcc; do
        local_org_image=${org}/${short_product}:${tag}
        for registry in build-docker.couchbase.com registry.gitlab.com; do
            remote_org_image=${registry}/${org}/${short_product}:${tag}
            docker tag ${local_org_image} ${remote_org_image}
            docker push ${remote_org_image}
            docker rmi ${remote_org_image}
        done
        docker rmi ${local_org_image}
    done
done
