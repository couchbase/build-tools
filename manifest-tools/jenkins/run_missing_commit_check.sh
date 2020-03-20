#!/bin/sh -ex

PRODUCT=$1
shift
RELEASE=$1
shift

reporef_dir=/data/reporef
metadata_dir=/data/metadata

# Update reporef. Note: This script requires /home/couchbase/reporef
# to exist in three places, with that exact path:
#  - The Docker host (currently mega3), so it's persistent
#  - Mounted in the Jenkins slave container, so this script can be run
#    to update it
#  - Mounted into the ubuntu-1604-recreate-build-manifest container, and
#    passed as the --reporef_dir argument to find_missing_commits
# Remember that when passing -v arguments to "docker run" from within a
# container (like the Jenkins slave), the path is interpreted by the
# Docker daemon, so the path must exist on the Docker *host*.
if [ -z "$(ls -A $reporef_dir)" ]
then
  echo "reporef dir is empty"
  exit 1
fi

if [ ! -e .repo ]; then
    # This only pre-populates the reporef for Server git code. Might be able
    # to do better in future.
    repo init -u git://github.com/couchbase/manifest -g all -m branch-master.xml
fi
repo sync --jobs=6 > /dev/null

cd /data/metadata

# This script also expects a /home/couchbase/check_missing_commits to be
# available on the Docker host, and mounted into the Jenkins slave container
# at /home/couchbase/check_missing_commits, for basically the same reasons
# as above. Note: I tried initially to use a named Docker volume for this
# to avoid needing to create the directory on the host; however, Docker kept
# changing the ownership of the mounted directory to root in that case.

rm -rf product-metadata
git clone git://github.com/couchbase/product-metadata > /dev/null

release_dir=product-metadata/${PRODUCT}/missing_commits/${RELEASE}
if [ ! -e "${release_dir}" ]; then
    echo "Cannot run check for unknown release ${RELEASE}!"
    exit 1
fi

# Sync Gateway annoyingly has a different layout and repository for manifests
# compared to the rest of the company. In particular they re-use "default.xml"
# changing the release name, which is hard for us to track. Therefore we just
# hard-code default.xml here. It would take more effort to handle checking for
# missing commits in earlier releases.
if [ "x${PRODUCT}" = "xsync_gateway" ]; then
    manifest_repo=git://github.com/couchbase/sync_gateway
    current_manifest=manifest/default.xml
    echo
    echo
    echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    echo "ALERT: product is sync_gateway, so forcing manifest to default.xml"
    echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    echo
else
    manifest_repo=git://github.com/couchbase/manifest
    current_manifest=${PRODUCT}/${RELEASE}.xml
fi

echo
echo "Checking for missing commits in release ${RELEASE}...."
echo

cd ${release_dir}

set +ex
failed=0

for previous_manifest in $(cat previous-manifests.txt); do
    echo "Checking ${previous_manifest}"
    find_missing_commits \
        --manifest_repo ${manifest_repo} \
        --reporef_dir ${reporef_dir} \
        -i ok-missing-commits.txt \
        -m merge-projects.txt \
        ${PRODUCT} \
        ${previous_manifest} \
        ${current_manifest}
    failed=$(($failed + $?))
done

exit $failed
