#!/bin/bash

UPSTREAM_BRANCH=$1

case ${UPSTREAM_BRANCH} in
  stabilization-f69489) echo "alice";;
  stabilization-5949a1cb71) echo "6.5.2";;
  stabilization-3b6982ce7f) echo "7.0.0";;
  stabilization-02ea049d7a) echo "6.6.3";;
  stabilization-5e11053887) echo "7.0.2";;
  stabilization-8bc2f61b7c) echo "7.1.2";;
  stabilization-667a908755) echo "7.1.x";;
  stabilization-b057463c08) echo "7.1.4";;
  stabilization-0020a08254) echo "7.2.2";;
  stabilization-40cfb8705b) echo "7.2.5";;
  stabilization-6a10f3f81d) echo "7.6.2";;
  stabilization-c8b0f90c72) echo "7.6.5";;
  stabilization-0cde515801) echo "7.6.6";;
  stabilization-1cffa2bc98) echo "columnar-1.0.5";;
  stabilization-27a661be67) echo "columnar-1.1.1";;
  log4jfix-22d4e6a278) echo "6.6.4";;
  log4jfix-5e11053887) echo "7.0.3";;
  morpheus|trinity|neo|cheshire-cat|mad-hatter|master|6.5.x-docs|goldfish|ionic|phoenix) echo "${UPSTREAM_BRANCH}";;
  *) echo "Don't know how to handle upstream branch: ${UPSTREAM_BRANCH}"; exit 1;;
esac
