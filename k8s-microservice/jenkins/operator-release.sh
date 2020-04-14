#!/bin/bash -ex

INTERNAL_TAG=${VERSION}-${BLD_NUM}

docker pull couchbase/couchbase-operator-internal:${INTERNAL_TAG}
echo @@@@@@@@@@@@@
echo Pushing couchbase/operator:${PUBLIC_TAG} image...
echo @@@@@@@@@@@@@
docker tag couchbase/couchbase-operator-internal:${INTERNAL_TAG} \
  couchbase/operator:${PUBLIC_TAG}
docker push couchbase/operator:${PUBLIC_TAG}

if [ x$LATEST = xtrue ]; then
    echo @@@@@@@@@@@@@
    echo Updating couchbase/operator:latest...
    echo @@@@@@@@@@@@@
    docker tag couchbase/couchbase-operator-internal:${INTERNAL_TAG} \
      couchbase/operator:latest
    docker push couchbase/operator:latest
    docker rmi couchbase/operator:latest
fi

docker rmi couchbase/couchbase-operator-internal:${INTERNAL_TAG}
docker rmi couchbase/operator:${PUBLIC_TAG}

docker pull couchbase/couchbase-admission-internal:${INTERNAL_TAG}
echo @@@@@@@@@@@@@
echo Pushing couchbase/admission-controller:${PUBLIC_TAG} image...
echo @@@@@@@@@@@@@
docker tag couchbase/couchbase-admission-internal:${INTERNAL_TAG} \
  couchbase/admission-controller:${PUBLIC_TAG}
docker push couchbase/admission-controller:${PUBLIC_TAG}
if [ x$LATEST = xtrue ]; then
    echo @@@@@@@@@@@@@
    echo Updating couchbase/admission-controller:latest...
    echo @@@@@@@@@@@@@

    docker tag couchbase/couchbase-admission-internal:${INTERNAL_TAG} \
      couchbase/admission-controller:latest
    docker push couchbase/admission-controller:latest
    docker rmi couchbase/admission-controller:latest
fi

docker rmi couchbase/couchbase-admission-internal:${INTERNAL_TAG}
docker rmi couchbase/admission-controller:${PUBLIC_TAG}

# Upload artifacts to S3

RELEASE_DIR=/releases/couchbase-operator/${PUBLIC_TAG}
mkdir -p ${RELEASE_DIR}
cd ${RELEASE_DIR}
for file in /latestbuilds/couchbase-operator/${VERSION}/${BLD_NUM}/*${BLD_NUM}*; do
  filename=$(basename ${file/${VERSION}-${BLD_NUM}/${PUBLIC_TAG}})
  cp -av ${file} ${filename}
  sha256sum ${filename} > ${filename}.sha256
  s3cmd -c ~/.ssh/live.s3cfg put -P ${filename} ${filename}.sha256 \
    s3://packages.couchbase.com/kubernetes/${PUBLIC_TAG}/
done