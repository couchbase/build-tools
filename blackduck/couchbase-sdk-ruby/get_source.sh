#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

TAG=$VERSION
git clone ssh://git@github.com/couchbase/couchbase-ruby-client.git
pushd couchbase-ruby-client
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi
git submodule update --init --recursive

# We use a SHA of http-parser that is slightly newer than the last
# released version v2.9.4, and Black Duck can't identify it. This
# package is unmaintained, so we will likely never depend on a newer
# version; but just in case, only update this back to v2.9.4 if it's
# still "v2.9.4++" according to git describe.
if [ -d ext/third_party/http_parser ]; then
    pushd ext/third_party/http_parser
    if [[ "$(git describe --tags)" =~ ^v2.9.4.* ]]; then
        echo "Reset http_parser to v2.9.4 for scan"
        git checkout v2.9.4
    fi
    popd
fi

function unset_bundle_path() {
    bundle config unset --local path
}

pip3 install -r ext/couchbase/third_party/snappy/third_party/benchmark/requirements.txt

bundle config set --local path './gems'
bundle install
trap unset_bundle_path EXIT

popd
