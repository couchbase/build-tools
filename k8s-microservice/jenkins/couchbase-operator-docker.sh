#!/bin/bash -ex

SCRIPT_DIR=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

echo "Downloading ${PRODUCT} ${VERSION}-${BLD_NUM} artifacts..."
curl -O http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/couchbase-autonomous-operator-image_${VERSION}-${BLD_NUM}.tgz

echo "Extracting"
tar xvf *.tgz

build_and_push() {
    directory=$1
    vanilla_image=$2
    openshift_image=$3
    naughty_image=$4

    pushd ${directory}
    echo "Building vanilla '${directory}' Docker image"
    docker build --pull -f Dockerfile -t ${vanilla_image} .

    echo "Pushing to Docker Hub"
    docker push ${vanilla_image}

    echo "Building OpenShift '${directory}' Docker image"
    docker build --pull -f Dockerfile.rhel \
       --build-arg PROD_VERSION=${VERSION} \
       --build-arg OPERATOR_BUILD=${BLD_NUM} \
       --build-arg OS_BUILD=${OS_BUILD} \
       -t ${openshift_image} \
       -t ${naughty_image} \
       .

    echo "Pushing to internal Docker registry and Docker Hub"
    docker push ${openshift_image}
    docker push ${naughty_image}

    docker rmi ${vanilla_image} ${openshift_image} ${naughty_image}

    popd
}

build_and_push operator \
    index.docker.io/couchbase/couchbase-operator-internal:${VERSION}-${BLD_NUM} \
    build-docker.couchbase.com/couchbase/couchbase-operator-rhel:${VERSION}-${BLD_NUM} \
    index.docker.io/couchbase/couchbase-operator-internal:rhel-${VERSION}-${BLD_NUM}

build_and_push admission \
    index.docker.io/couchbase/couchbase-admission-internal:${VERSION}-${BLD_NUM} \
    build-docker.couchbase.com/couchbase/couchbase-admission-rhel:${VERSION}-${BLD_NUM} \
    index.docker.io/couchbase/couchbase-admission-internal:rhel-${VERSION}-${BLD_NUM}
