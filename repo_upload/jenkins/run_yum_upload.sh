#!/bin/bash -e

# Ensure we have the latest image
docker pull couchbasebuild/centos-74-yum-upload:latest

# This script expects a /home/couchbase/repo_upload to be available
# on the Docker host, and mounted into the Jenkins slave container at
# /home/couchbase/repo_upload
cd /home/couchbase/repo_upload
rm -rf product-metadata
git clone git://github.com/couchbase/product-metadata > /dev/null

if [ "${BETA}" = "false" ]
then
    CONF_FILE="repo_upload_${LOCATION}.ini"
    PRODUCT_FILE="base.json"
else
    CONF_FILE="repo_upload_${LOCATION}.beta.ini"
    PRODUCT_FILE="beta.json"
fi

echo
echo "Uploading RPM packages for Couchbase Server releases..."
echo

docker run --rm -u couchbase \
    -w /home/couchbase/repo_upload \
    -v /home/couchbase/jenkinsdocker-ssh:/ssh \
    -v /home/couchbase/repo_upload:/home/couchbase/repo_upload \
    -v /home/couchbase/repo_upload/${CONF_FILE}:/etc/repo_upload.ini \
    couchbasebuild/centos-74-yum-upload \
        -e ${EDITION} -D ${CONFDIR} -f ${PRODUCT_FILE}
