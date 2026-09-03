# Rebuild

This utility is designed to automate the process of rebuilding Docker containers whenever there are changes to the base images on which these containers are built. It identifies which images need to be rebuilt by comparing the date they were created with the create date of the base image, and generates trigger files which can be used to initiate the rebuild process in Jenkins.

### Usage

When run with no arguments, the generate_trigger_files script will identify stale images for all products, editions and versions on each registry

```python
./generate_trigger_files.py   # handles all products, editions and versions on each registry
```

Or, runs can be targeted to specific subsets of images:

```python
./generate_trigger_files.py --product couchbase-server  # Target all couchbase-server images on all registries
./generate_trigger_files.py --product sync_gateway --edition enterprise  # Target only enterprise editions of all version of sync_gateway on all registries
./generate_trigger_files.py --product couchbase-server --edition enterprise --version 7.6.2 --registry docker  # Target only couchbase-server 7.6.2 enterprise on docker hub
./generate_trigger_files.py --product couchbase-server --edition enterprise --version 7.2.3,7.2.4 --registry redhat  # Target couchbase-server 7.2.3 and 7.2.4 (enterprise only) on the redhat registry
```

### Arguments

All arguments are optional, and if not provided will be targeted broadly (e.g. if no `product` is provided, all products are targeted). Each argument also accepts either a single value, or a comma-separated list of values

- **-p, --product**: Specify the product(s) for which images should be checked.
- **-e, --edition**: Specify the edition(s) (e.g. community, enterprise).
- **-v, --version**: Specify the version(s) to check.
- **-r, --registry**: Specify the registries to be checked (available options are `docker` and `redhat`)
- **-c, --checks**: Specify which checks may flag an image for rebuild (`base` and/or `packages`). Defaults to both.
- **-s, --shard**: Restrict package checks to a subset of images (see [Checks and sharding](#checks-and-sharding)).
- **-l, --log-level**: Set the logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL). Defaults to INFO.

### Checks and sharding

Two independent checks can flag an image for rebuild:

- **base** - compares the create date of the image against its base image. This only needs `skopeo` and `git`, so it is cheap and never touches the Docker daemon.
- **packages** - boots each image and asks its package manager whether updates are available, then does the same for the base image so that only *product-specific* updates trigger a rebuild. This pulls and runs every image, so it is by far the more expensive of the two.

`--checks` selects which of these run, and `--shard N/M` restricts the package checks (only) to a stable 1-in-M subset of images, with `N` zero-based. Passing `auto` in place of `N` derives the index from the day of the week, so a single daily job gives each image one package check per week (`auto` therefore needs an `M` of at most 7):

```python
./generate_trigger_files.py --checks base                       # cheap: base image drift only
./generate_trigger_files.py --checks base,packages --shard auto/7  # base image drift daily, package checks for 1/7 of images
./generate_trigger_files.py --checks packages --shard 3/7        # package checks for one specific shard
```

Shard membership is a hash of `registry/product/edition/version`, so it is stable between runs and rebalances on its own as products and versions come and go. Images excluded by `--checks` or `--shard` are reported in the rebuild skips summary with the reason, and anything a disabled check stopped us acting on (a newer base image seen during a `--checks packages` run, say) is reported as a `Note:` against that image, so a cheap run never looks like a clean bill of health.

Note that a base image check which flags a rebuild short-circuits the package check for that image - there is no duplicated work when both checks run.

### Failures

An image we could not check is never reported as an image that needs nothing done. Anything that stops a check completing - a tag that is listed by the registry but fails to pull, an image whose package manager cannot reach its repos, a base image we could not compare against - is reported under **Processing Failures** in the run summary and makes the script exit non-zero, which fails the Jenkins job. Trigger files for the images that *were* checked are still written, and the trigger stage still runs, so a failure here is advisory rather than blocking.

The same applies to enumerating a registry: if `skopeo list-tags` fails after its retries, that registry is reported as a failure for the affected product rather than contributing zero tags to an otherwise clean run. The other registry is still checked.

Note that only the **packages** check pulls images, so a `--checks base` run will not notice a tag that has become unpullable, and under `--shard N/M` a broken tag may take up to M runs to be picked up.

### Skipping Rebuilds

The utility checks for a `.norebuild` file at `http://releases.service.couchbase.com/builds/releases/${PRODUCT}/${VERSION}/.norebuild`. If this file exists for a specific product/version combination, that version will not be flagged for rebuild even if the base image is newer.

### Project structure

- **src/**: Contains the main source code, including modules for metadata handling, Dockerfile parsing, registry interaction etc.
- **triggers/**: Directory where the generated trigger files are stored
- **repos/**: Local clones of the necessary repositories are stored here
