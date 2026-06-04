#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

SOURCE_DIR=mcp-server-couchbase

# Prefer the published PyPI sdist so we scan exactly what ships. Build an sdist
# from the git repository if the version required has not been published
python -m pip download --no-deps --no-binary couchbase-mcp-server --no-cache-dir couchbase-mcp-server==$VERSION || true
TARBALL=$(find . -maxdepth 1 -name "couchbase_mcp_server-*.tar.gz")
if [ -z "${TARBALL}" ]; then
    if [ "$RELEASE" == "$VERSION" ] || [ "$RELEASE" == "master" ]; then
        RELEASE="main"
    fi
    echo "Version $VERSION does not exist on PyPI, checking out git repository and building sdist."
    git clone https://github.com/couchbase/mcp-server-couchbase.git $SOURCE_DIR
    pushd $SOURCE_DIR
    TAG="v${VERSION}"
    if git rev-parse --verify --quiet $TAG >& /dev/null
    then
        echo "Tag $TAG exists, checking it out"
        git checkout $TAG
    else
        echo "No tag $TAG, checking out $RELEASE"
        git checkout $RELEASE
    fi
    # Build outside the clone so the output directory doesn't end up
    # inside the sdist itself
    uv build --sdist --out-dir ../bd-sdist
    popd
    mv bd-sdist/*.tar.gz .
    rm -rf $SOURCE_DIR bd-sdist
    TARBALL=$(find . -maxdepth 1 -name "couchbase_mcp_server-*.tar.gz")
fi

tar -xf $TARBALL
TARBALL_CONTENTS_DIR=$(basename $TARBALL .tar.gz)
mkdir $SOURCE_DIR
mv $TARBALL_CONTENTS_DIR/* $SOURCE_DIR
rm -rf $TARBALL_CONTENTS_DIR
rm $TARBALL

pushd $SOURCE_DIR
# Export the locked runtime dependencies as a pinned requirements.txt for the
# PIP detector. The dev tools (ruff, pytest, ...) are an extra in
# pyproject.toml, so "uv export" already excludes them by default; --no-dev is
# belt and braces.
uv export --frozen --no-dev --no-emit-project --no-hashes --output-file requirements.txt
# Install those dependencies into the scan job's venv so the PIP native
# inspector can build the full dependency graph from it.
pip install -r requirements.txt
popd
