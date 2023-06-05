Yum/Apt Repo Management
-----------------------

This directory comprises two tools:

 - cb-repos-tool (in the repo-tool subdir) which manages a collection of
   yum/apt repositories locally (on the NAS) and also syncs them to S3
 - couchbase-release-build (in the couchbase-release subdir) which is
   the build/test script for the "couchbase-release" rpm/deb metapackage
   customers use to add the yum/apt repositories to their machines

We introduce the concept of a "target", which is a set of yum/apt
repositories for a single outbound purpose. The primary public repos are
in a target called "release". There are also targets for "staging",
"beta", and "beta-staging", and could be other in future. Each target is
completely disjoint from the others; it contains different sets of repos
which may contain different packages for different products, and there
are independent metapackages for each.

Each target will generally contain one yum and one apt repository called
"linux" where we store the single-linux installers for Couchbase Server,
along with some number of separate repositories containing packages for
specific Linux distributions ("focal", "rhel9", etc). For Server 7.1.0
and newer, only the single-linux installers should be uploaded. For
earlier releases, along with other products such as couchbase-lite-c
which require Linux-distribution-specific packages, the installers will
be located in the distribution-specific repositories.

cb-repos-tool also creates a simple .repo/.list file describing each
yum/apt repository it creates, which is synced as part of the archive to
S3. The couchbase-release metapackage in turn attempts to download both
the "linux" repo/list file as well as the repo/list file for the local
Linux distribution. It is only considered a failure if *neither* of
those repo/list files are available. This will not generally happen
since the "linux" repository should always be available (although in the
yum world since there are actually separate repositories per
architecture, it could happen if someone attempted to install on say an
armhf machine).
