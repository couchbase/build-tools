#!/usr/bin/env bash

set -e
rm -rf deps
mkdir deps
pushd deps

short_version=$(curl -Lfs "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/SUPPORTED_NEWER.txt")
go_version=$(curl -Lfs "https://raw.githubusercontent.com/couchbaselabs/golang/main/versions/${short_version}.txt")

cbdep=cbdep-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)

curl -LO https://packages.couchbase.com/cbdep/${cbdep}
chmod a+x ${cbdep}

./$cbdep install -d . golang ${go_version}

export PATH=$(pwd)/go${go_version}/bin:$PATH
popd

GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o repo.exe main.go
