#!/bin/bash -e

# Ensure we have the latest image
docker pull couchbasebuild/ubuntu-1604-apt-upload:latest

# This script expects a /home/couchbase/repo_upload to be available
# on the Docker host, and mounted into the Jenkins slave container at
# /home/couchbase/repo_upload
cd /home/couchbase/repo_upload
rm -rf product-metadata
git clone git://github.com/couchbase/product-metadata > /dev/null

echo
echo "Uploading Debian packages for Couchbase Server releases..."
echo

if [ "${BETA}" = "false" ]
then
    CONF_FILE="repo_upload_${PRODUCT_LINE}_${LOCATION}.ini"
    PRODUCT_FILE="base.json"
else
    CONF_FILE="repo_upload_${PRODUCT_LINE}_${LOCATION}.beta.ini"
    PRODUCT_FILE="beta.json"
fi
set -x
docker run --rm -u couchbase \
    -w /home/couchbase/repo_upload \
    -v /home/couchbase/jenkinsdocker-ssh:/ssh \
    -v /home/couchbase/repo_upload:/home/couchbase/repo_upload \
    -v /home/couchbase/repo_upload/${CONF_FILE}:/etc/repo_upload.ini \
    couchbasebuild/ubuntu-1604-apt-upload-mobile \
        -e ${EDITION} -D ${CONFDIR} -f ${PRODUCT_FILE} -p ${PRODUCT} -l ${PRODUCT_LINE}
