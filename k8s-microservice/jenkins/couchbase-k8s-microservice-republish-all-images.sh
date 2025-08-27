#!/bin/bash -e

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh



# Returns the set of GA architectures for a given product/version.
vanilla-arches() {
    short_product=$1
    version=$2

    arches="none"

    # For Docker Hub, we use multi-arch images, and we don't (yet?)
    # have any that are arm64-only. So if the image exists at all,
    # we can assume it's at least for amd64.
    image=docker.io/couchbase/${short_product}:${version}
    if image_exists ${image}; then
        if image_has_arch ${image} arm64; then
            arches="linux/amd64,linux/arm64"
        else
            arches="linux/amd64"
        fi
    fi

    echo ${arches}
}

rhcc-arches() {
    short_product=$1
    version=$2

    arches="none"

    # For now, at least, RHCC doesn't allow for multi-arch images, so
    # we upload them with different tags.
    image_base=registry.connect.redhat.com/couchbase/${short_product}:${version}
    if image_exists ${image_base}; then
        if image_exists ${image_base}-arm64; then
            arches="linux/amd64,linux/arm64"
        else
            arches="linux/amd64"
        fi
    fi

    echo ${arches}
}

function republish() {
    product=$1
    version=$2

    short_product=${product/couchbase-/}

    # Figure out the arches for cb-vanilla
    status Inquiring Docker Hub to check arches for ${short_product} ${version}...
    vanilla_arches=$(vanilla-arches ${short_product} ${version})

    # Figure out if we need to do RHCC, and if so, what arches
    NEXT_BLD=0
    if product_in_rhcc "${PRODUCT}"; then
        status Inquiring RHCC to check arches for ${short_product} ${version}...
        rhcc_arches=$(rhcc-arches ${short_product} ${version})
        if [ "${rhcc_arches}" != "none" ]; then
            NEXT_BLD=$(${script_dir}/../../rhcc/scripts/compute-next-rhcc-build.sh \
                -p ${product} -v ${version})
        fi
    fi

    # Rebuild the images on internal registry - this will update the base image.
    # Pass the -P argument to have the new images Published.
    status Rebuilding ${product} ${version}
    ${script_dir}/util/build-k8s-images.sh -P \
        -p ${product} -v ${version} -o ${NEXT_BLD} \
        -d "${vanilla_arches}" -r "${rhcc_arches}"
}


# Main program logic begins here


ROOT=$(pwd)

# For now we simply hard-code the set of product names.
for product in \
    couchbase-operator \
    couchbase-operator-backup \
    couchbase-exporter \
    couchbase-fluent-bit
do
    header Processing ${product}
    short_product=${product/couchbase-/}

    # Retrieve the list of tags from Docker Hub. We assume that this is
    # the maximal set of versions that are supported (ie, there aren't
    # any versions that are in RHCC but not in Docker Hub).
    status "Retrieving set of tags from Docker Hub..."
    versions=$(skopeo --override-os linux \
        list-tags docker://docker.io/couchbase/${short_product} \
        | jq -r '.Tags[]')

    for version in ${versions}; do

        # Skip anything with a hyphen in it - MPs, betas, etc. This
        # handily also filters out the redundant -dockerhub tags.
        if [[ ${version} =~ "-" ]]; then
            status "Skipping non-GA version ${version}"
            continue
        fi

        # See if this version is marked to be ignored - some older
        # versions just won't build anymore due to changes in package
        # repositories, etc.
        if curl --silent --fail \
            http://releases.service.couchbase.com/builds/releases/${product}/${version}/.norebuild
        then
            status "Skipping ${product} ${version} due to .norebuild"
            continue
        fi

        republish ${product} ${version}
    done
done
