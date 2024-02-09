#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

git clone ssh://git@github.com/couchbase/gocb.git
pushd gocb
TAG="v$VERSION"
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

GOVER=$(grep "^go " go.mod | cut -d " " -f2)

if cbdep install -d "${WORKSPACE}/extra" golang ${GOVER}; then
    echo "Using golang ${GOVER} from go.mod" >&2
else
    echo "Couldn't install go ${GOVER} from go.mod, using latest supported" >&2
    LATEST_MAJOR_MINOR=$(curl -s https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/SUPPORTED_NEWER.txt)
    GOVER=$(curl -s https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/${LATEST_MAJOR_MINOR}.txt)
    cbdep install -d "${WORKSPACE}/extra" golang ${GOVER}
fi

export PATH="${WORKSPACE}/extra/go${GOVER}/bin:$PATH"

popd
