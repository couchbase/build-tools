#!/bin/bash -e

download_analytics_jars() {
  # Get cbdep tool
  curl -L -o cbdep http://downloads.build.couchbase.com/cbdep/cbdep.linux
  chmod 755 cbdep

  mkdir -p thirdparty-jars

  # Determine old version builds
  for version in $(
    perl -lne '/SET \(bc_build_[^ ]* "(.*)"\)/ && print $1' analytics/CMakeLists.txt
  ); do

    ./cbdep install -d thirdparty-jars analytics-jars ${version}

  done

  rm cbdep
}

# Main script starts here

download_analytics_jars
