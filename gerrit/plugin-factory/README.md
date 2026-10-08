# Gerrit-plugin-factory

This container can be used to build gerrit plugins. Running go.sh will build the container image defined in this dir and dump the plugin jars (built via build-plugin calls in the Dockerfile) into ./plugins. You can of course also use the produced image for debugging or produce ad-hoc builds of specific plugins at runtime with e.g. `docker run --rm -it -v $(pwd)/build-plugin:/usr/local/bin/build-plugin -v $(pwd)/plugins:/plugins local/gerrit-plugin-factory`

The default behavior of the build-plugin script is simply to find the highest stable minor version of a given major version in the plugin's branch list and use that same branch of the gerrit source tree for the build, but if we need to override this for any reason (if current version has a problem preventing build from succeeding for instance) a number of options are available: `PLUGIN_MINOR_VERSION`, `PLUGIN_MAJOR_VERSION`, `GERRIT_MINOR_VERSION`, `GERRIT_MAJOR_VERSION`, `PLUGIN_BRANCH` and `GERRIT_BRANCH` will be used if present in the environment when calling build-plugin - e.g. `PLUGIN_MINOR_VERSION=1 build-plugin foo`

Setting `RUN_TESTS=1` additionally runs `bazel test plugins/<plugin>:<plugin>_tests` after the build, where the plugin has such a target - e.g. `RUN_TESTS=1 build-plugin oauth`

Patches in `patches/<plugin>/*.patch` are applied with `git apply` to the plugin's checkout before it is built; a patch that no longer applies fails the build. Each applied patch is recorded in the `patches` column of versions.txt as `<file>@<blob sha>`. The Dockerfile must `COPY` each plugin's patch dir before its `build-plugin` line - e.g. `COPY patches/uploadvalidator /patches/uploadvalidator` - and ad-hoc runs need it mounted, e.g. `-v $(pwd)/patches:/patches`

Given a full version (`./go.sh 3.14.3`), the Gerrit tree is checked out at that release tag (`v3.14.3`) rather than the tip of `stable-3.14`, so plugins are built against the exact API of the server they will run on. Given `major.minor` only, branch discovery is unchanged. `go.sh` refuses to run if its output dir `./plugins-<version>` already exists.
