#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${SCRIPT_DIR}/../../utilities/shell-utils.sh"

MAVEN_VERSION=3.9.11
cbdep install -d ${WORKSPACE}/extra mvn ${MAVEN_VERSION}
export PATH=${WORKSPACE}/extra/mvn-${MAVEN_VERSION}/bin:$PATH

# Each manifest builds ONE driver flavor, named by its FLAVOR annotation; the
# flavor's module sits behind a flavor-<FLAVOR> Maven profile (see
# couchbase-jdbc-driver/jdbc-driver-build.sh). The caller already did repo
# init/sync and wrote a resolved manifest.xml into cwd, the source root.
FLAVOR=$(annot_from_manifest FLAVOR)
[ -n "${FLAVOR}" ] || error "no FLAVOR annotation in the build manifest"
MODULE=${FLAVOR}-jdbc-driver
DRIVER_DIR=couchbase-jdbc-driver
[ -f "${DRIVER_DIR}/${MODULE}/pom.xml" ] || error "flavor '${FLAVOR}' has no module ${DRIVER_DIR}/${MODULE}"

# Build the flavor and let it produce an authoritative BOM
# (license-automation-plugin -> <module>/target/bom.txt) rather than have
# Black Duck scan the driver's Maven project: the driver jar shades most of
# what it ships (core-io's netty, jackson, guava, ...), which a dependency
# tree can't see. bom.txt lists the shaded artifacts too; bom_no_shadowed.txt
# would leave out code the jar really ships. Everything in the BOM resolves
# from Maven Central, so `package` suffices. -Dmaven.javadoc.skip=true: the
# shaded jar trips javadoc, and the BOM doesn't need it.
mvn -B \
    -f "${DRIVER_DIR}/pom.xml" \
    -P "flavor-${FLAVOR}" \
    -DskipTests -Dmaven.javadoc.skip=true \
    package

BOM="${DRIVER_DIR}/${MODULE}/target/bom.txt"
[ -s "${BOM}" ] || error "no BOM generated at ${BOM}"

# Convert the BOM into poms Black Duck can scan. create-maven-boms.py turns
# the "groupId:artifactId:version" list into poms with all transitive deps
# excluded, so Detect records exactly the BOM contents and nothing else.
# detect-config.json points Detect's source path at this directory, so the
# driver's own reactor poms are never scanned.
BOM_POMS=driver-boms
rm -rf "${BOM_POMS}" && mkdir "${BOM_POMS}"
uv run --project "${SCRIPT_DIR}/../scripts" --quiet \
    "${SCRIPT_DIR}/../scripts/create-maven-boms.py" \
        --outdir "${BOM_POMS}" \
        --file "${BOM}"
