#!/bin/bash -ex

# example usage
# get_source.sh couchbase-sdk-analytics-python 1.0.0 1.0.0 9999

# Set to "couchbase-sdk-analytics-python", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your scan-config.json specified a release key for this version,
# that value will be passed here
RELEASE=$2
# One of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

PACKAGE=couchbase-analytics
REPO=https://github.com/couchbase/analytics-python-client
SOURCE_DIR=analytics-python-client
# PyPI normalizes sdist filenames (PEP 625), so the dashes become underscores.
TARBALL="${PACKAGE//-/_}-${VERSION}.tar.gz"

# Only build from git if the version is not on PyPI yet.
# Would be nice to ignore build isolation (--no-build-isolation), but the pip resolver
# does not want to play nice and it does not impact the scan.  Maybe a nice-to-have in the future.
python -m pip download --no-deps --no-binary "${PACKAGE}" --no-cache-dir "${PACKAGE}==${VERSION}" || true
if [ ! -f "${TARBALL}" ]; then
    # A version key without its own release (an upcoming version) scans main.
    if [ "${RELEASE}" == "${VERSION}" ]; then
        RELEASE=main
    fi
    echo "Version ${VERSION} does not exist on PyPI, building an sdist from ${RELEASE}."
    # Full clone: the SDK's version file is generated from git describe.
    git clone --branch "${RELEASE}" "${REPO}" "${SOURCE_DIR}"
    python -m pip install --upgrade setuptools
    (cd "${SOURCE_DIR}" && python setup.py sdist -d ..)
    rm -rf "${SOURCE_DIR}"
    TARBALL=$(ls "${PACKAGE//-/_}"-*.tar.gz)
fi

# The sdist includes setup.py and pyproject.toml, so the BD detector search
# will satisfy the HIGH accuracy requirement.
# SEE: https://documentation.blackduck.com/bundle/detect/page/components/detectors.html
tar -xf "${TARBALL}"
mv "${TARBALL%.tar.gz}" "${SOURCE_DIR}"
rm "${TARBALL}"
