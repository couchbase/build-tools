This directory contains scripts useful for using with the Jenkins "XShell"
(cross-platform shell) plugin: https://plugins.jenkins.io/xshell/

Scripts in here should always come in pairs, one with no extension (for
execution on Unix) and one with a .bat extension (for Windows).

download_build_source - accepts the standard four "build co-ordinates"
(product, release, version, bld_num) on the command line. If they are not
specified, assumes that the variables PRODUCT, RELEASE, VERSION, and BLD_NUM
are defined in the environment. Downloads and unpacks the source tarball
from latestbuilds corresponding to that build. Also downloads the
corresponding build.properties file and saves it locally with the exact name
"build.properties", so it can be injected into the Jenkins job environment.
