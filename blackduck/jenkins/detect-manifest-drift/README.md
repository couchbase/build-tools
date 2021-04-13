This script is used to track drift between versions listed in tlm/deps/manifest.cmake and tlm/deps/couchbase-server-black-duck-manifest.yaml

Entries in the black-duck-manifest.yaml can take multiple forms, the simplest being `product: [ versions ]` where there is a direct mapping between cbdeps and blackduck versions. Where these versions diverge we can use an additional `cbdeps-versions` field to highlight differences

````
boost:
    versions: [ 1.74.0.2 ]
    cbdeps-versions: [ 1.74.0 ]
````

The script will exit with a failure code when there is a divergence between the versions/cbdeps-versions/value in black-duck-manifest and the version in manifest.cmake. It will also fail if there are products in manifest.cmake which are not listed in black-duck-manifest. If there is a legitimate reason for such a condition to exist, a dummy entry can be created to ensure the package is not identified as "missing", e.g. `cbpy: []`

Note: cbdeps-versions will almost always be a single-item list, unless manifest.cmake specifies multiple versions of a dependency for different platforms.