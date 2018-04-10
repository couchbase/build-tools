#!/bin/bash -e

RELEASE=$1
shift

# Ensure we have the latest image
docker pull couchbasebuild/ubuntu-1604-recreate-build-manifest:latest

# Update reporef. Note: This script requires /home/couchbase/reporef
# to exist in three places, with that exact path:
#  - The Docker host (currently mega3), so it's persistent
#  - Mounted in the Jenkins slave container, so this script can be run
#    to update it
#  - Mounted into the ubuntu-1604-recreate-build-manifest container, and
#    passed as the --reporef_dir argument to find_missing_commits
# Remember that when passing -v arguments to "docker run" from within a
# container (like the Jenkins slave), the path is interpretted by the
# Docker daemon, so the path must exist on the Docker *host*.
cd /home/couchbase/reporef
if [ ! -e .repo ]; then
    repo init -u git://github.com/couchbase/manifest -g all -m branch-master.xml
fi
repo sync --jobs=6 > /dev/null

# This script also expects a /home/couchbase/check_missing_commits to be
# available on the Docker host, and mounted into the Jenkins slave container
# at /home/couchbase/check_missing_commits, for basically the same reasons
# as above. Note: I tried initially to use a named Docker volume for this
# to avoid needing to create the directory on the host; however, Docker kept
# changing the ownership of the mounted directory to root in that case.
cd /home/couchbase/check_missing_commits
rm -rf product-metadata
git clone git://github.com/couchbase/product-metadata > /dev/null

metadata_dir=product-metadata/couchbase-server/missing_commits/${RELEASE}
if [ ! -e "${metadata_dir}" ]; then
    echo "Cannot run check for unknown release ${RELEASE}!"
    exit 1
fi
cd ${metadata_dir}

echo
echo "Checking for missing commits in release ${RELEASE}...."
echo

for previous_manifest in $(cat previous-manifests.txt); do
    docker run --rm -u couchbase \
        -w $(pwd) \
        -v /home/couchbase/check_missing_commits:/home/couchbase/check_missing_commits \
        -v /home/couchbase/reporef:/home/couchbase/reporef \
        -v /home/couchbase/jenkinsdocker-ssh:/home/couchbase/.ssh \
        couchbasebuild/ubuntu-1604-recreate-build-manifest \
            find_missing_commits \
            --reporef_dir /home/couchbase/reporef \
            -i ok-missing-commits.txt \
            -m merge-projects.txt \
            couchbase-server \
            ${previous_manifest} \
            couchbase-server/${RELEASE}.xml
done
