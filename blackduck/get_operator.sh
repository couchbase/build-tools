#!/bin/bash -ex

MANIFEST=$1

GOFILE=go1.10.3.linux-amd64.tar.gz
WORKSPACE=$(pwd)

# Check out the main source code
mkdir -p src
cd src

repo init -u git://github.com/couchbase/manifest -g all -m couchbase-operator/${MANIFEST}
repo sync --jobs=6

# Download go (brute-force solution for now)
cd ${WORKSPACE}
mkdir -p golang
cd golang
echo "Downloading golang..."
curl --continue - \
  --silent --show-error \
  -o ${GOFILE} https://dl.google.com/go/${GOFILE}
tar xf ${GOFILE}
export PATH=${PATH}:$(pwd)/go/bin

# Build glide tool
echo "Building glide..."
cd ${WORKSPACE}
mkdir -p gopath
export GOPATH=$(pwd)/gopath
go get github.com/Masterminds/glide
export PATH=${PATH}:${GOPATH}/bin

# Use glide to download all dependencies
echo "Downloading operator dependencies..."
cd ${WORKSPACE}/src/goproj/src/github.com/couchbase/couchbase-operator
glide install --strip-vendor
