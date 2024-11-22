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

Simply edit the file cb-dependencies.txt to specify new dependencies.
This is a normal pip requirements.txt-style file, so you can use
specifiers like

    gnureadline; platform_system != 'Windows'

for any platform-dependent packages.

# Building packages

Once you've made any necessary changes either to the manifest or here in
build-tools, submit the change(s) to Gerrit, then run the job
http://server.jenkins.couchbase.com/job/toy-manifest-build/, choose
option "A" (be sure to check the TRIGGER_BUILD option), and specify your
Gerrit change(s) at the bottom. This will create toy build packages with
a build number above 50000 on latestbuilds.

# Note on Black Duck

The Unix cbpy builds include a `cb-requirements.txt` file, which
contains the locked versions of all dependencies used (including any
platform-specific ones). Black Duck has a "buildless" detector which can
parse a raw `requirements.txt` file, so the `couchbase-server` and
`couchbase-columnar` `get_additional_source.sh` scripts arrange for that
`cb-requirements.txt` file to be left in the source directory as just
`requirements.txt`. Black Duck can then process this file and include
all Python dependencies in the corresponding reports.

For reporting the version of Python itself in Black Duck, we still
include a template `black-duck-manifest.yaml.in` which will packaged as
`cbpy-black-duck-manifest.yaml` in the final package.
