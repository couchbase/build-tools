#!/bin/bash -ex

SCRIPT_DIR=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

ARTIFACT_URL=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}-image_${VERSION}-${BLD_NUM}.tgz
VANILLA_IMAGE=build-docker.couchbase.com/couchbase/${PRODUCT}:${VERSION}-${BLD_NUM}
OPENSHIFT_IMAGE=build-docker.couchbase.com/couchbase/${PRODUCT}-rhel:${VERSION}-${BLD_NUM}
NAUGHTY_IMAGE=index.docker.io/couchbase/${PRODUCT}-internal:rhel-${VERSION}-${BLD_NUM}

echo "Downloading ${PRODUCT} ${VERSION}-${BLD_NUM} artifacts..."
curl -O "${ARTIFACT_URL}"

echo "Extracting"
tar xvf *.tgz

pushd ${PRODUCT}

########################
# Vanilla docker build #
########################

${SCRIPT_DIR}/update-base.sh Dockerfile
echo "Building 'plain' Docker image for ${PRODUCT}"
docker build -f Dockerfile -t "${VANILLA_IMAGE}" .

echo "Pushing to internal docker registry"
docker push "${VANILLA_IMAGE}"

docker rmi "${VANILLA_IMAGE}"


#########################
# Openshift image build #
#########################

${SCRIPT_DIR}/update-base.sh Dockerfile.rhel
echo "Building OpenShift Docker image for ${PRODUCT}"
docker build -f Dockerfile.rhel \
   --build-arg PROD_VERSION=${VERSION} \
   --build-arg PROD_BUILD=${BLD_NUM} \
   --build-arg OS_BUILD=${OS_BUILD} \
   -t "${OPENSHIFT_IMAGE}" \
   -t "${NAUGHTY_IMAGE}"
   .

echo "Pushing to internal Docker registry and Docker Hub"
docker push "${OPENSHIFT_IMAGE}"
docker push "${NAUGHTY_IMAGE}"

docker rmi "${OPENSHIFT_IMAGE}" "${NAUGHTY_IMAGE}"


popd
