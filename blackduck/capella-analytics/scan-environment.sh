#!/bin/bash -ex

# Only do anything if get_additional_source.sh left us something to find
javadir=$(echo ${WORKSPACE}/extra/install/openjdk-*)
[ ! -d "${javadir}" ] && exit

cat <<EOF
PATH=${javadir}/bin:${PATH}
JAVA_HOME=${javadir}
EOF
