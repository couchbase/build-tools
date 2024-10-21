#!/bin/bash -ex

go_version_file=$(cat golang/versions/SUPPORTED_NEWER.txt).txt
go_version=$(cat golang/versions/${go_version_file})
cbdep install golang ${go_version} -d ${WORKSPACE}/extra
export PATH=${WORKSPACE}/extra/go${go_version}/bin:$PATH
