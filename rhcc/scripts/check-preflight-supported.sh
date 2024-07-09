#!/usr/bin/env bash

# This script is intended to run daily. It checks the version of preflight
# present in the adjacent publishing script against the supported versions
# presented by the API, and proposes a change to update to current if our
# existing version is no longer supported

set -e

publish_script=./rhcc-certify-and-publish.sh
couchbase_preflight_version=$(grep 'PREFLIGHTVER=' ${publish_script} | sed 's/^[[:space:]]*PREFLIGHTVER=\([^[:space:]]*\).*/\1/')
upstream_preflight_versions="$(curl -fsL https://catalog.redhat.com/api/containers/v1/tools | jq -r '.data[] | select(.enabled_for_testing==true and .name=="github.com/redhat-openshift-ecosystem/openshift-preflight") | .version')"

changed_script=$(mktemp)
trap "rm -f ${changed_script}" EXIT

current_version_is_ok=false

while IFS= read -r version; do
    if [ "${version}" = "${couchbase_preflight_version}" ]; then
        current_version_is_ok=true
    fi
    upstream_highest_version=$version
done <<< "$upstream_preflight_versions"

if ${current_version_is_ok}; then
    echo "Preflight version ${couchbase_preflight_version} still supported, no action needed"
else
    echo "In-use preflight version $couchbase_preflight_version is unsupported, proposing move to $upstream_highest_version"
    sed "s/PREFLIGHTVER=${couchbase_preflight_version}/PREFLIGHTVER=${upstream_highest_version}/g" "${publish_script}" >> $changed_script
    cp $changed_script $publish_script
    chmod a+x $publish_script
    git remote -v | grep cbgerrit && git remote remove cbgerrit
    git remote add cbgerrit ssh://${GERRIT_USER}@review.couchbase.org:29418/build-tools
    git commit -am "Bump preflight to ${upstream_highest_version}"
    git push cbgerrit HEAD:refs/for/master
fi
