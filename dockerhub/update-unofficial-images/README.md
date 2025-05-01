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
- **-l, --log-level**: Set the logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL). Defaults to INFO.

### Project structure

- **src/**: Contains the main source code, including modules for metadata handling, Dockerfile parsing, registry interaction etc.
- **triggers/**: Directory where the generated trigger files are stored
- **repos/**: Local clones of the necessary repositories are stored here
