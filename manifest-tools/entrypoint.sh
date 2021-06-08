#!/bin/sh -ex

PRODUCT=${1}
RELEASE=${2}

mkdir -p /home/couchbase/.ssh

gosu couchbase sh -c "ssh-keyscan github.com >> ~/.ssh/known_hosts && \
                      git config --global user.name \"${git_user_name}\" && \
                      git config --global user.email \"${git_user_email}\" && \
                      git config --global color.ui auto && \
                      /app/jenkins/run_missing_commit_check.sh ${PRODUCT} ${RELEASE}"
