#!/bin/bash -ex

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))
source ${script_dir}/../utilities/shell-utils.sh

usage() {
    echo "Usage: VERSION=<version> GITHUB_TOKEN=<token> [PACKAGES=\"rpm deb\"] $0"
    echo
    echo "  PACKAGES  which formats to build; default \"rpm deb\". Set it to a single"
    echo "            format to run on a host that only has that toolchain, e.g."
    echo "            PACKAGES=deb on Debian, PACKAGES=rpm on el9."
    exit 1
}

# The two toolchains rarely coexist on one agent, so each format can be built separately.
wants_package() {
    case " ${PACKAGES} " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

check_environment() {
    chk_set VERSION
    chk_set GITHUB_TOKEN
    chk_cmd tar awk

    local fmt
    for fmt in ${PACKAGES}; do
        case "${fmt}" in
            rpm) chk_cmd rpmbuild ;;
            deb) chk_cmd dpkg-deb ;;
            *)   error "unknown package format '${fmt}' in PACKAGES, expected rpm or deb" ;;
        esac
    done
}

# --root-owner-group needs dpkg 1.19+; without it the agent's uid lands in the archive.
check_deb_tools() {
    local dpkg_version
    dpkg_version=$(dpkg-deb --version | head -1 | sed -e 's/.*version //' -e 's/[.[:space:]]*$//')
    if version_lt "${dpkg_version}" "1.19.0"; then
        error "dpkg-deb ${dpkg_version} is too old; 1.19.0 or later is needed for --root-owner-group"
    fi
}

# Neither format takes the '-' in a prerelease tag verbatim. '~' is the prerelease marker
# for both and sorts before the GA release (1.0.0~beta.2 < 1.0.0); dropping the hyphen
# would sort after it and make the GA look like a downgrade.
package_version() {
    local v=${VERSION#v}
    v=${v//-/\~}
    echo "${v}"
}

# Debian's arch names are the GOARCH values, so one mapping serves the Go build and the deb.
pkg_arch() {
    case "$1" in
        x86_64)  echo amd64 ;;
        aarch64) echo arm64 ;;
        *)       error "unsupported architecture '$1', expected x86_64 or aarch64" ;;
    esac
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

    # Two statements: with "local goarch=$(...)" the status is local's, so set -e would
    # not catch error() inside the substitution.
    goarch=$(pkg_arch ${arch})

    header "Building payload for ${arch}"

    local stage=${BUILD_DIR}/stage-${arch}
    rm -rf ${stage}
    mkdir -p ${stage}/opt/couchbase/fleetmanager/bin
    mkdir -p ${stage}/opt/couchbase/var/lib/fleetmanager

    # The source is an extracted release tarball with no .git of its own, so buildvcs=auto
    # would walk up and stamp the *enclosing* build-tools checkout's revision into the
    # binary - wrong provenance, and a hard failure ("exit status 128") whenever that git
    # call doesn't work, e.g. dubious ownership under a container UID.
    pushd ${REPO_DIR}
    CGO_ENABLED=0 GOOS=linux GOARCH=${goarch} go build \
        -buildvcs=false \
        -trimpath \
        -ldflags "-s -w" \
        -o ${stage}/opt/couchbase/fleetmanager/bin/fleetmanager-server \
        ./cmd/server
    popd

    cp -a ${REPO_DIR}/cmd/ui/dist ${stage}/opt/couchbase/fleetmanager/ui

    # The stage is a complete filesystem image, so both packagings can just wrap it.
    # Ownership is the exception - the fleetmanager uid only exists at install time - and
    # is supplied by %attr in %files and by the deb's postinst.
    install -Dpm 0644 ${COMMON_DIR}/couchbase-fleetmanager.service \
        ${stage}${UNITDIR}/${PRODUCT}.service
    install -Dpm 0640 ${COMMON_DIR}/fleetmanager.env \
        ${stage}/etc/couchbase/fleetmanager/fleetmanager.env
    install -Dpm 0644 ${COMMON_DIR}/credentials.json.example \
        ${stage}/usr/share/doc/${PRODUCT}/credentials.json.example
    install -Dpm 0644 ${COMMON_DIR}/README.md \
        ${stage}/usr/share/doc/${PRODUCT}/README.md

    # install -D makes parents 0755; dpkg takes directory modes from the archive.
    chmod 0750 ${stage}/etc/couchbase/fleetmanager
    chmod 0700 ${stage}/opt/couchbase/var/lib/fleetmanager
}

build_rpm() {
    local arch=$1

    header "Building ${arch} RPM"

    local stage=${BUILD_DIR}/stage-${arch}
    local fm_version
    fm_version=$(package_version)

    # _buildhost and dist are pinned so the artifact doesn't vary with the build agent.
    rpmbuild -bb ${script_dir}/rpm/couchbase-fleetmanager.spec \
        --target ${arch} \
        --define "_topdir ${BUILD_DIR}/rpmbuild" \
        --define "_rpmdir ${DIST_DIR}" \
        --define "_buildhost reproducible" \
        --define "dist .el9" \
        --define "fm_stage ${stage}" \
        --define "fm_version ${fm_version}" \
        --define "fm_release ${BLD_NUM}"
}

build_deb() {
    local arch=$1
    local debarch
    debarch=$(pkg_arch ${arch})

    header "Building ${arch} deb"

    local debroot=${BUILD_DIR}/deb-${arch}
    local fm_version
    fm_version=$(package_version)

    # A copy: DEBIAN/ must sit inside the packed tree, and would otherwise reach the rpm's
    # buildroot as an unpackaged file.
    rm -rf ${debroot}
    cp -a ${BUILD_DIR}/stage-${arch} ${debroot}

    # Mirrors the spec's deliberately unowned directories: /opt/couchbase/var belongs to
    # couchbase-server, and owning it here would let a purge rmdir its tree. postinst
    # creates the one leaf we need.
    rm -rf ${debroot}/opt/couchbase/var

    # After the prune and before DEBIAN/ exists, so it counts what is actually shipped.
    local installed_size
    installed_size=$(du -ks ${debroot} | awk '{print $1}')

    # control has no comment syntax: it deliberately has no couchbase-server dependency
    # (Fleet Manager may manage a remote cluster), and depends on adduser and
    # init-system-helpers for what %pre and dh_installsystemd would otherwise provide.
    mkdir -p ${debroot}/DEBIAN
    sed -e "s|@@VERSION@@|${fm_version}-${BLD_NUM}|" \
        -e "s|@@ARCH@@|${debarch}|" \
        -e "s|@@INSTALLED_SIZE@@|${installed_size}|" \
        ${script_dir}/deb/control.in > ${debroot}/DEBIAN/control
    chmod 0644 ${debroot}/DEBIAN/control

    install -pm 0644 ${script_dir}/deb/conffiles ${debroot}/DEBIAN/conffiles
    for scriptlet in postinst prerm postrm; do
        install -pm 0755 ${script_dir}/deb/${scriptlet} ${debroot}/DEBIAN/${scriptlet}
    done

    # Everything ships root:root and postinst fixes the paths needing the fleetmanager
    # user. -Zgzip matches couchbase-release-build; zstd needs dpkg 1.21.18 to read.
    dpkg-deb --root-owner-group --build -Zgzip ${debroot} \
        ${DIST_DIR}/${PRODUCT}_${fm_version}-${BLD_NUM}-linux_${debarch}.deb
}

# Main
PRODUCT=couchbase-fleetmanager
GH_REPO=couchbase/lighthouse
GH_VERSION=${GH_VERSION:-2.79.0}

# Pinned, not overridable: the release number is assigned by the build system, so a
# caller-supplied value would produce an RPM whose name disagrees with its provenance.
BLD_NUM=9999
ARCHES=${ARCHES:-"x86_64 aarch64"}

# Narrow this to build on a host that has only one toolchain - see usage().
PACKAGES=${PACKAGES:-"rpm deb"}

BUILD_DIR=$(pwd)/build
REPO_DIR=${BUILD_DIR}/lighthouse
DIST_DIR=$(pwd)/dist

# Shared by both packagings, so owned by neither. UNITDIR is %{_unitdir} on el9 and the
# merged-/usr path on Debian; the spec's %{_unitdir} must agree or rpmbuild fails loudly.
COMMON_DIR=${script_dir}/common
UNITDIR=/usr/lib/systemd/system

check_environment
wants_package rpm && check_rpm_macros
wants_package deb && check_deb_tools

umask 022

rm -rf ${BUILD_DIR} ${DIST_DIR}
mkdir -p ${BUILD_DIR} ${DIST_DIR}

prepare_environment
get_source
install_toolchains
build_ui

status "Building ${PACKAGES// /, } for ${ARCHES// /, }"

for arch in ${ARCHES}; do
    build_payload ${arch}

    wants_package rpm && build_rpm ${arch}
    wants_package deb && build_deb ${arch}
done

header "Built packages"
find ${DIST_DIR} \( -name '*.rpm' -o -name '*.deb' \) -print
status "Publish these to /latestbuilds/${PRODUCT}/${VERSION#v}/${BLD_NUM}/"
