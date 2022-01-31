#!/bin/bash -ex

RELEASE=$1
VERSION=$2
BLD_NUM=$3

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

get_cbdep() {
  # Get cbdep tool
  curl -L -o cbdep http://downloads.build.couchbase.com/cbdep/cbdep.linux
  chmod 755 cbdep
}

download_analytics_jars() {
  get_cbdep
  mkdir -p thirdparty-jars

  # Determine old version builds
  for version in $(
    perl -lne '/SET \(bc_build_[^ ]* "(.*)"\)/ && print $1' analytics/CMakeLists.txt
  ); do

    ./cbdep install -d thirdparty-jars analytics-jars ${version}

  done

  rm cbdep
}

create_analytics_poms() {
  get_cbdep
  # This will be also be added to PATH by scan-environment.sh in case
  # Detect needs it
  ./cbdep install -d ../extra/install openjdk 11.0.14+9
  javadir=$(pwd)/../extra/install/openjdk-11.0.14+9
  export PATH=${javadir}/bin:${PATH}
  export JAVA_HOME=${javadir}

  # We need to ask Analytics to build us a BOM, which we then convert
  # to a series of poms that Black Duck can scan. Unfortunately this
  # requires actually building most of Analytics. However, it does
  # allow us to bypass having Detect scan the analytics/ directory.
  pushd analytics
  mvn --batch-mode \
    -DskipTests -Drat.skip -Dformatter.skip=true \
    -Dcheckstyle.skip=true -Dimpsort.skip=true \
    -pl :cbas-install -am install
  popd

  mkdir -p analytics-boms
  "${SCRIPT_DIR}/create-maven-boms" \
    --outdir analytics-boms \
    --file analytics/cbas/cbas-install/target/bom.txt

  pushd analytics-boms
  for dir in *; do
    pushd ${dir}
    mvn dependency:purge-local-repository
    popd
  done
  popd

  # Delete all the built artifacts so BD doesn't scan them
  rm -rf install
}

# Main script starts here - decide which action to take based on VERSION

if [ "6.6.5" = $(printf "6.6.5\n${VERSION}" | sort -n | head -1) ]; then
  # 6.6.5 or higher
  create_analytics_poms
else
  download_analytics_jars
fi
