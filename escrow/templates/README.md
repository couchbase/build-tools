# Couchbase @@VERSION@@ Escrow

The scripts, source, and data in this directory can be used to produce
installer packages of Couchbase Server @@VERSION@@ Enterprise Edition
in both RPM and DEB formats, compatible with all supported Linux
distributions.

## Requirements

This script can be run on any flavor of Unix (Linux or MacOS) so long
as it has:

- bash
- Docker (at least 1.12)

Because the build toolchain is run inside Docker containers, you may
produce the installer packages for Linux while running on any platform.
The operating system you are running on does not have to be one of the
supported platforms.

The host machine should have at least 20-25 GB of free disk space for
the build process. This does not include the space used by this escrow
distribution itself.

The host machine should have at least two CPU cores (more preferred) and
8 GB of RAM.

The escrow distribution is self contained and should not even need access
to the internet, with two exceptions:

- Couchbase Analytics code is written in Java and built with Maven,
  and Maven needs to download a number of dependencies from Maven
  Central.
- V8's build scripts are extremely idiosyncratic and depend heavily on
  binaries downloaded directly from Google. This unfortunately means
  if Google decides to remove those binaries in future, that portion
  of the build will not succeed.

## Build Instructions

The escrow distribution contains a top-level directory named
`couchbase-server-@@VERSION@@`. cd into this directory, and then run

    ./build-couchbase-server-from-escrow.sh <host_path>

where <host_path> is the path to the volume the build script resides in
(required only if script is being run in a container)

That is all. The build will take roughly 30 minutes depending on the
speed of the machine.

Note: The `linux` worker is based on Centos7, and is used for both x86_64
and arm64 builds.

Once the build is complete, the installer packages and tools will be located
alongside the `couchbase-server-@@VERSION@@` directory. The build produces
multiple package types with consistent naming:

**Main installer packages:**
- RPM package:
  `couchbase-server-enterprise-@@VERSION@@-9999-linux.x86_64.rpm`
- DEB package:
  `couchbase-server-enterprise_@@VERSION@@-9999-linux_amd64.deb`

**Debug symbol packages:**
These packages are occasionally made available by Couchbase Support when
debugging specific problems. These packages should be installed _in addition_
to the main installer for debugging purposes:
- RPM debug package:
  `couchbase-server-enterprise-debuginfo-@@VERSION@@-9999-linux.x86_64.rpm`
- DEB debug package:
  `couchbase-server-enterprise-dbg_@@VERSION@@-9999-linux_amd64.deb`

**Tools packages:**
- Admin tools:
  `couchbase-server-admin-tools-@@VERSION@@-9999-linux_x86_64.tar.gz`
- Developer tools:
  `couchbase-server-dev-tools-@@VERSION@@-9999-linux_x86_64.tar.gz`

## Build Synopsis

The following is a very brief overview of the steps the build takes. THis
may be useful for someone who wishes to integrate a bug fix into an
escrowed release.

### Setting up the container

The `build-couchbase-server-from-escrow.sh` script creates an instance
of a Linux Docker container which contains all the necessary
toolchain elements (gcc, CMake, and so on). It starts this
container and then copies the `deps`, `golang`, and `src` directories into
the container under `/home/couchbase`. Finally it launches the script
`in-container-build.sh` inside the container to perform the actual build.

### Using pre-built third-party dependencies

The first stage of the `in-container-build.sh` script is setting up the
third-party dependencies, known as "cbdeps". Rather than compiling these
from source, the build uses pre-built packages that are included in the
distribution. These pre-built packages are copied into
`/home/couchbase/.cbdepscache` inside the container, where the main
Couchbase Server build process expects to find them.

The source code for each of these cbdeps is included in the `deps` directory
for reference and audit purposes only - it is not compiled during the build.
Some of these dependencies are exactly the same code as the upstream
third-party code, while others have Couchbase-specific code modifications.
The subdirectories of `deps` are clones of the original Git repositories,
so you can use `git` to view the commit logs and understand any modifications
that were made.

### Go

The Couchbase Server build requires one or more specific versions of the Go
language. The necessary `golang.org` distribution packages are included in
the `golang` directory. During the build, `in-container-build.sh` copies
these Go installations into `/home/couchbase/.cbdepscache`, where the main
Couchbase Server build process expects to find them.

### Couchbase Server source code

The Couchbase Server source code is located in the `src` directory.
Note: This directory was created originally by a tool named
[repo](https://source.android.com/docs/setup/download#repo), which
was developed for the Google Android project. It takes as input an
XML manifest which specifies a number of Git repositories. These
Git repositories are downloaded from specified branches and laid out
on disk in a structure defined by the manifest.

Most of the top-level directories under `src` are such Git repositories
containing Couchbase-specific code. There are also a number of
directories deeper in the directory hierarchy under the top-level
`godeps` and `goproj` directories. These contain Go language code, laid
out on disk as two "Go workspaces". This makes it easier for the build
process to compile them.

Many of the subdirectories under `goproj` are third-party code. Go
does not have a concept of binary "libraries" as such; it always builds
from source. Therefore the normal cbdeps mechanism was not useful for
pre-compiling them. Instead we created forks of those Go projects in
GitHub and then laid them out for builds using the repo manifest. A
few of these projects have Couchbase-specific changes as well.

As with the `deps` directories, all of the repo-managed directories in
`src` are Git repositories, and so you can use the `git` tool to view
their history.

### Couchbase Server build

The main build script driving the Couchbase Server build is

    src/cbbuild/scripts/jenkins/couchbase_server/server-linux-build.sh

The path reflects the fact that this package was normally built from
a Jenkins job. This script expects to be passed several parameters,
including whether to build the Enterprise or Community Edition of
Couchbase Server; the version number; and a build number.
`in-container-build.sh` invokes this script with the appropriate arguments
to build Couchbase Server @@VERSION@@ Enterprise Edition, specifying a fake
build number "9999".

Couchbase Server is built using [CMake](https://cmake.org/), and
`server-linux-build.sh` mostly does some workspace initialization and
then invokes CMake with a number of arguments. The CMake scripting
has innumerable stages and is out of scope of this document, but one
of the things it does is ensure that all of the cbdeps are "downloaded"
into `/home/couchbase/.cbdepscache` along with the necessary versions
of the Go compiler. It then uncompressed those packages for use in the
remainder of the build.

### Packaging

The package (creation of a `.rpm` or `.deb` file) is handled separately.
The code and configuration for this step is in `src/voltron`.
`server-linux-build.sh` configures the `voltron` directory according to
the specific build, and then invokes a Ruby script called `server-rpm.rb`
or `server-deb.rb` in the `voltron` directory, passing a number of
arguments.

The resulting packages (including RPM and DEB installers, debug symbol
packages, and tools packages) are then moved to the top of the build
workspace. Finally, outside the container, the original
`build-couchbase-server-from-escrow.sh` script copies these packages
from inside the container to the host directory.

## Escrow build notes

- The Docker container for a given build is left running after the build
  is complete. If it is running and `build-couchbase-server-from-escrow.sh`
  is re-run, the container will be re-used.

- The escrow build scripts are designed to not repeat long build steps
  such as compiling cbdeps if built a second time. The containers also
  have CCache installed, so re-builds should be relatively quick.

- The scripts are not heavily tested for re-builds. So we
  recommend that if you make local modifications, you should do one final
  clean build by first ensuring that the Docker worker container is
  destroyed. You can use `docker rm -f <worker>` for this. The worker
  name will always be `linux-worker`. You can use `docker ps -a` to
  show you any existing containers.
