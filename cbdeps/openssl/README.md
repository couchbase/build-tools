The files in this directory are designed to be able to build OpenSSL 1.1.1*,
3.0.x and [3.0.x with FIPS](https://www.openssl.org/docs/manmaster/man7/fips_module.html).

When enabling FIPS globally, it's necessary that the openssl binary knows
where the config files are located, this is controlled by OPENSSLDIR which
is baked into the binary at build time. To ensure correctness we must
`configure` the build with the appropriate `prefix` (/opt/couchbase on
linux/mac) along with the correct `openssldir` (we use `.../etc/openssl` and
`.../etc/openssl/fips` for non-FIPS and FIPS builds respectively to establish
some distinction)

Although we want the `prefix` and `openssldir` to align with the final destination
of our files, at build time these files should land in the standard location
used by our scripts, which is passed to the build scripts as `INSTALL_DIR`.
To that end, we provide a `DESTDIR` to `make install`, ensuring the openssl
directory structure remains intact within
`/home/couchbase/jenkins/workspace/cbdeps-platform-build/install/opt/couchbase`
on linux/mac, and
`C:\Jenkins\workspace\cbdeps-platform-build\install\Program Files\Couchbase\Server`
on Windows.

We then flatten these down to INSTALL_DIR after the fact, moving bin, lib, etc,
include and share (the latter only on mac/linux) to the root of INSTALL_DIR

Finally in `CMakeLists.txt`, we copy the bin, etc and lib directories from our
build into `CMAKE_INSTALL_PREFIX`. It should be ok for these files to land
anywhere for non-FIPS builds (as the openssl conf files would be unused)
however as the `OPENSSLDIR` is baked into the openssl binary, and the config
file in that location has an absolute path to `fipsmodule.cnf`, openssl with
FIPS will not function as expected outside `/opt/couchbase` without modification
of the `fipsmodule.cnf` path in `openssl.cnf`, and environment variable overrides
of `OPENSSLDIR`, `OPENSSL_ENGINES_DIR` and `OPENSSL_MODULES_DIR`. If/when we employ
FIPS-enabled openssl, we will need to ensure the non-root install
process is updated accordingly.
