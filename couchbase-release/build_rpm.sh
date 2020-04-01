#!/bin/bash -e

this_dir=$(dirname $0)

STAGING=$1

# Version and release are passed in as environment variables by go.sh
if [ -e "$VERSION" -o -e "$RELEASE" ]
then
  echo "Env vars not specified, this script should be triggered by go.sh"
  exit 1
fi

if [[ "${STAGING}" == "yes" ]]; then
    STAGE_EXT="-staging"
else
    STAGE_EXT=""
fi

REL_NAME="couchbase-release${STAGE_EXT}-${VERSION}-${RELEASE}"

rm -rf ~/rpmbuild
mkdir ~/rpmbuild
for dir in BUILD BUILDROOT RPMS SOURCES SPECS SRPMS; do
    mkdir ~/rpmbuild/${dir}
done

pushd ${this_dir}/rpm

sed -e "s/%STAGING%/${STAGE_EXT}/g" tmpl/couchbase-Base.repo.in \
    > couchbase-Base.repo
sed -e "s/%STAGING%/${STAGE_EXT}/g" \
    -e "s/%VERSION%/${VERSION}/g"\
    -e "s/%RELEASE%/${RELEASE}/g" \
    tmpl/couchbase-release.spec.in > couchbase-release.spec

cp -p ../GPG-KEY-COUCHBASE-1.0 ~/rpmbuild/SOURCES
cp -p *.repo ~/rpmbuild/SOURCES
rpmbuild -bb couchbase-release.spec

popd

cp ~/rpmbuild/RPMS/x86_64/${REL_NAME}.x86_64.rpm ${REL_NAME}-x86_64.rpm
