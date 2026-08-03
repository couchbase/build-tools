#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
source ${script_dir}/../utilities/shell-utils.sh

usage() {
    echo "Usage: VERSION=<version> GITHUB_TOKEN=<token> $0"
    exit 1
}

check_environment() {
    chk_set VERSION
    chk_set GITHUB_TOKEN
    chk_cmd rpmbuild tar awk
}

# Without systemd-rpm-macros rpmbuild still succeeds, but leaves %{_unitdir} and the
# %systemd_* scriptlets unexpanded, so the unit is silently never registered.
check_rpm_macros() {
    if [[ "$(rpm --eval '%systemd_post foo.service')" == *"%systemd_post"* ]]; then
        error "systemd-rpm-macros is not installed; install rpm-build and systemd-rpm-macros"
    fi
}

prepare_environment() {
    header "Preparing environment"

    TOOLDIR=$(mktemp -d -q --tmpdir=$(pwd) toolsXXXXX)

    cbdep install -d ${TOOLDIR} gh ${GH_VERSION}
    export PATH=${TOOLDIR}/gh-${GH_VERSION}/bin:${PATH}
}

get_source() {
    header "Downloading ${PRODUCT} source for version ${VERSION}"

    if [[ "${VERSION}" != v* ]]; then
        VERSION="v${VERSION}"
    fi

    rm -rf ${REPO_DIR}
    mkdir -p ${REPO_DIR}

    local tarball=${BUILD_DIR}/${GH_REPO##*/}-${VERSION}.tar.gz

    gh release download ${VERSION} --repo ${GH_REPO} --archive=tar.gz -O ${tarball}
    tar -xz -C ${REPO_DIR} --strip-components=1 -f ${tarball}
}

install_toolchains() {
    header "Installing toolchains"

    if [[ -z "${GOVERSION}" ]]; then
        GOVERSION=$(awk '/^go /{print $2; exit}' ${REPO_DIR}/go.mod)
        status "Go version from go.mod: ${GOVERSION}"
    fi
    if [[ -z "${NODE_VERSION}" ]]; then
        # cmd/ui/.nvmrc is the UI's own pin and is an exact version, which is what cbdep
        # needs. package.json's engines.node is a semver range ("^24.0.0") and so cannot be
        # used directly.
        NODE_VERSION=$(tr -d '[:space:]' < ${REPO_DIR}/cmd/ui/.nvmrc)
        NODE_VERSION=${NODE_VERSION#v}
        status "Node version from cmd/ui/.nvmrc: ${NODE_VERSION}"
    fi
    chk_set GOVERSION
    chk_set NODE_VERSION

    cbdep install -d ${TOOLDIR} golang ${GOVERSION}
    cbdep install -d ${TOOLDIR} nodejs ${NODE_VERSION}
    export PATH=${TOOLDIR}/go${GOVERSION}/bin:${TOOLDIR}/nodejs-${NODE_VERSION}/bin:${PATH}

    # go.mod's directive is a minimum, so without this Go may fetch its own toolchain.
    export GOTOOLCHAIN=local
}

build_ui() {
    header "Building UI"

    pushd ${REPO_DIR}/cmd/ui

    cp .npmrc.example .npmrc

    export CYPRESS_INSTALL_BINARY=0

    npm ci
    npm run build

    popd
}

build_payload() {
    local arch=$1
    local goarch

    case "${arch}" in
        x86_64)  goarch=amd64 ;;
        aarch64) goarch=arm64 ;;
        *)       error "unsupported architecture '${arch}', expected x86_64 or aarch64" ;;
    esac

    header "Building payload for ${arch}"

    local stage=${BUILD_DIR}/stage-${arch}
    rm -rf ${stage}
    mkdir -p ${stage}/opt/couchbase/fleetmanager/bin
    mkdir -p ${stage}/opt/couchbase/var/lib/fleetmanager

    pushd ${REPO_DIR}
    CGO_ENABLED=0 GOOS=linux GOARCH=${goarch} go build \
        -trimpath \
        -ldflags "-s -w" \
        -o ${stage}/opt/couchbase/fleetmanager/bin/fleetmanager-server \
        ./cmd/server
    popd

    cp -a ${REPO_DIR}/cmd/ui/dist ${stage}/opt/couchbase/fleetmanager/ui
}

build_rpm() {
    local arch=$1

    header "Building ${arch} RPM"

    local stage=${BUILD_DIR}/stage-${arch}

    # rpm forbids '-' in Version:, so a prerelease tag such as v1.0.0-beta.2 cannot be used
    # verbatim. '~' is rpm's prerelease marker and sorts BEFORE the GA release
    # (1.0.0~beta.2 < 1.0.0); deleting the hyphen instead would yield 1.0.0beta.2, which sorts
    # AFTER 1.0.0 and would make the eventual GA release look like a downgrade.
    local fm_version=${VERSION#v}
    fm_version=${fm_version//-/\~}

    # _buildhost and dist are pinned so the artifact doesn't vary with the build agent.
    rpmbuild -bb ${script_dir}/rpm/couchbase-fleetmanager.spec \
        --target ${arch} \
        --define "_topdir ${BUILD_DIR}/rpmbuild" \
        --define "_rpmdir ${DIST_DIR}" \
        --define "_sourcedir ${script_dir}/rpm" \
        --define "_buildhost reproducible" \
        --define "dist .el9" \
        --define "fm_stage ${stage}" \
        --define "fm_version ${fm_version}" \
        --define "fm_release ${BLD_NUM}"
}

# Main
PRODUCT=couchbase-fleetmanager
GH_REPO=couchbase/lighthouse
GH_VERSION=${GH_VERSION:-2.79.0}

# Pinned, not overridable: the release number is assigned by the build system, so a
# caller-supplied value would produce an RPM whose name disagrees with its provenance.
BLD_NUM=9999
ARCHES=${ARCHES:-"x86_64 aarch64"}

BUILD_DIR=$(pwd)/build
REPO_DIR=${BUILD_DIR}/lighthouse
DIST_DIR=$(pwd)/dist

check_environment
check_rpm_macros

rm -rf ${BUILD_DIR} ${DIST_DIR}
mkdir -p ${BUILD_DIR} ${DIST_DIR}

prepare_environment
get_source
install_toolchains
build_ui

for arch in ${ARCHES}; do
    build_payload ${arch}
    build_rpm ${arch}
done

header "Built packages"
find ${DIST_DIR} -name '*.rpm' -print
status "Publish these to /latestbuilds/${PRODUCT}/${VERSION#v}/${BLD_NUM}/"
