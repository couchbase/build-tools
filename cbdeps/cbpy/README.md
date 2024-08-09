# Overview

This directory contains build steps to create "cbpy", which is a
standalone customized Python 3 package. This package will be installed
on customer machines as part of Server, and will be used for all Python
3 scripts that we ship.

Therefore, if you write any Python 3 scripts that require a new third-party
Python library, we must add it here to ensure that it is available in
production.

This used to be part of the Server build itself, but as it grew somewhat
more complex, it made sense to pull it out to a separate cbdeps package.

# Python version

The cbdeps 2.0 VERSION (ie, the VERSION annotation in the manifest)
corresponds to the Python version, so to update Python itself, update
the manifest VERSION.

# Adding new packages or updating package versions

Simply edit the file cb-dependencies.txt to specify new dependencies
that are required on all platforms. If there are some which are
platform-specific, edit one or more of the five cb-dependencies-*.txt
files for the specific platform/arch(es) you need.

# Custom packages

If there is a package we need that isn't available in conda-forge, we
can create a conda package recipe in a directory under conda-pkgs/all.
This at a minimum requires a file named "meta.yaml" which describes how
to build the package. See the link below for additional information:

https://docs.conda.io/projects/conda-build/en/latest/resources/define-metadata.html

Also place these dependencies in cb-dependencies.txt, with the correct
version number.

For platform-specific packages, you can create a subdirectory under
conda-pkgs with the name linux-x86_64, linux-aarch64, macosx-x86_64,
macosx-arm64, or windows-amd64, and put the package subdirectory under
there. In that case, also add the dependency name and version to the
corresponding cb-dependencies-xxxxxx.txt file.

# Stubbed packages

We have a few packages that we stub out, generally because something we
require depends on them but we don't actually need/want to ship them
(often due to suspect licensing conditions). In that case, we can create
a "fake" conda package in a directory under conda-pkgs/stubs. The recipe
format is the same as above, although most of the information is left
blank.

In this case, also add the dependency name and version to
cb-dependencies-stubs.txt.

# Building packages

Once you've made any necessary changes either to the manifest or here in
build-tools, submit the change(s) to Gerrit, then run the job
http://server.jenkins.couchbase.com/job/toy-manifest-build/, choose
option "A" (be sure to check the TRIGGER_BUILD option), and specify your
Gerrit change(s) at the bottom. This will create toy build packages with
a build number above 50000 on latestbuilds.

# Updating Black Duck manifest

For the moment at least, after the test packages are built and you're
happy with them, there's one final manual step. Download each of the
five .tgz packages to a directory somewhere, then run

    cd verify-black-duck-manifest
    rye sync
    rye run verify-black-duck-manifest -v <CBPY VERSION> -d <PATH TO TGZs>

This will ensure that the conda environments created for the packages
match the Black Duck manifest. For now it will only report problems,
requiring you to manually fix the blackduck/black-duck-manifest.yaml.in
file; this is to ensure that all changes are expected.

Once this is done, commit this last change, and you're ready to submit.
