#!/bin/bash -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MAVEN_VERSION=3.9.5
cbdep install -d ${WORKSPACE}/extra mvn ${MAVEN_VERSION}
mv ${WORKSPACE}/extra/mvn-${MAVEN_VERSION} ${WORKSPACE}/extra/mvn
export PATH=${WORKSPACE}/extra/mvn/bin:$PATH

# The connector builds a single SDK flavor selected by the repo manifest's
# <annotation name="SDK"> (analytics | operational | both). Its dependencies
# are declared in the matching flavor submodule, which sits behind a flavor-*
# Maven profile -- without activating that profile the build (and the BOM) sees
# no dependencies. The caller already did repo init/sync and wrote a resolved
# manifest.xml (cwd is the source root, connector checked out at path=".").
MANIFEST=manifest.xml
[ -f "${MANIFEST}" ] || MANIFEST=.repo/manifest.xml
SDK=$(
    grep -oE '<annotation[[:space:]]+name="SDK"[[:space:]]+value="[^"]+"' "${MANIFEST}" |
    sed -E 's/.*value="([^"]+)".*/\1/' | head -1
)

case "${SDK}" in
    operational) PROFILES="flavor-couchbase-analytics" ;;
    both|all)    PROFILES="flavor-enterprise-analytics,flavor-couchbase-analytics" ;;
    *)           PROFILES="flavor-enterprise-analytics" ;;  # analytics / default
esac
echo "Manifest SDK='${SDK:-<unset>}' -> Maven profile(s): ${PROFILES}"

# Build the connector flavor(s). Rather than have Black Duck unpack and scan the
# dependency jars -- which over-counts test deps and can't enumerate shaded
# transitives -- we let the build produce an authoritative BOM
# (license-automation-plugin -> cbas/cbas-jdbc-taco/<flavor>-taco/target/bom.txt)
# and feed that to Detect (see create-maven-boms.py below).
#
# Use `install`, not `package`: the BOM lists the connector's own unpublished
# SNAPSHOTs (the JDBC driver, the asterix client), and Detect later runs
# `dependency:tree` against the generated BOM poms, where those artifacts must
# resolve from the local .m2. `install` puts them there; `package` only writes
# each module's target/. Both *.local profiles build the driver/asterix from
# source so the SNAPSHOTs exist. -Dmaven.javadoc.skip=true: the driver's shaded
# uber-jar trips javadoc's module path ("reads package ... from both", see
# DEV_WORKFLOW.md) and javadoc isn't needed to generate the BOM.
mvn -B \
    -P "${PROFILES}" \
    -Dasterixdb-jdbc.local -Dcouchbase-jdbc.local \
    -DskipTests -Dmaven.javadoc.skip=true -Dsource-format.skip=true \
    -f pom.xml \
    install

# Convert each built flavor's BOM into a set of poms Black Duck can scan.
# create-maven-boms.py turns the "groupId:artifactId:version" list into poms
# with all transitive deps excluded, so Detect records exactly the BOM contents
# and nothing else. detect-config.json points Detect's source path at this
# directory, so the connector's own reactor poms are never scanned.
BOM_POMS=connector-boms
rm -rf "${BOM_POMS}"
shopt -s nullglob
boms=(cbas/cbas-jdbc-taco/*/target/bom.txt)
if [ ${#boms[@]} -eq 0 ]; then
    echo "ERROR: no BOM generated under cbas/cbas-jdbc-taco/*/target/bom.txt" >&2
    exit 1
fi
for bom in "${boms[@]}"; do
    # .../<flavor>-taco/target/bom.txt -> <flavor>-taco; keep flavors in separate
    # subdirs so a two-flavor (SDK=both) build doesn't clobber one BOM's poms
    # with the other's (create-maven-boms.py names output dirs 0, 1, 2, ...).
    flavor=$(basename "$(dirname "$(dirname "${bom}")")")
    outdir="${BOM_POMS}/${flavor}"
    mkdir -p "${outdir}"
    echo "Converting BOM ${bom} -> ${outdir}"
    uv run --project "${SCRIPT_DIR}/../scripts" --quiet \
        "${SCRIPT_DIR}/../scripts/create-maven-boms.py" \
            --outdir "${outdir}" \
            --file "${bom}"
done
