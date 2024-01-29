#!/bin/bash -ex

# blackduck complains about node_modules directory if it is not there,
# so run "npm" install for all packages.

# NOTE: this script should install an appropriate version of 'nodejs'
# using cbdep. However, at the moment due to CBD-4283 this doesn't work.
# Hence node 20.11.0 has been installed manually (using nvm) on the BD
# scan VM, and this script assumes it is on $PATH. If we need a newer
# version than that in future, we can log into the VM and run "nvm
# install -s <version>" followed by "nvm alias default <version>" to
# make it the default version on $PATH. This takes a long time (the -s
# option makes it build nodejs from source, which is required due to
# CBD-4283).

rm -rf couchbase-cloud/cmd/cp-ui couchbase-cloud/cmd/cp-ui-tests couchbase-cloud/cmd/cp-ui-docs-screenshots
for dir in $(find . -name package.json \
  -exec dirname {} \;)
do
    pushd $dir
    npm install
    popd
done
