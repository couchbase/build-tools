#!/bin/bash

this_dir=$(dirname $0)

if [[ -n $1 ]]; then
    STAGING="yes"
else
    STAGING="no"
fi

python -mplatform | grep -i ubuntu > /dev/null 2>&1
ret=$?

if [[ ${ret} -eq 0 ]]; then
    echo "Building on Ubuntu"
    ${this_dir}/build_deb.sh ${STAGING}
    exit 0
fi

python -mplatform | grep -i centos > /dev/null 2>&1
ret=$?

if [[ ${ret} -eq 0 ]]; then
    echo "Building on CentOS"
    ${this_dir}/build_rpm.sh ${STAGING}
    exit 0
fi
