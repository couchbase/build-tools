#!/usr/bin/env -S uv run

# /// script
# dependencies = [
#   "PyYAML"
# ]
# [tool.uv]
# exclude-newer = "2025-03-04T00:00:00Z"
# ///

import re
import yaml


def heading(text):
    print()
    print("*" * (len(text)+4))
    print(f"* {text} *")
    print("*" * (len(text)+4))


def short_version(text):
    return re.sub(r'\.0$', '', re.sub(r'^(v|V)', '', text))


def product_and_version(words):
    # Retrieve product and version from a DECLARE_DEP line in manifest.cmake
    product = words[1][1:]
    version = re.sub("(-cb[0-9]+|-couchbase|_.*)", '',
                     words[4] if(words[2] == "V2") else words[3])
    return {"product": product, "version": version}


def cbdeps():
    with open('tlm/deps/manifest.cmake') as f:
        # return [{product,version}, ...] for all DECLARE_DEP lines in manifest
        return [dict(t) for t in {tuple(d.items()) for d in map(product_and_version, [
            line.split() for line in f.readlines() if line.startswith("DECLARE_DEP")
        ])}]


def blackduck_manifest():
    with open('tlm/deps/couchbase-server-black-duck-manifest.yaml') as f:
        return yaml.safe_load(f)


def sort(d):
    return sorted(d, key=lambda k: k['cbdep_dependency']['product'])


def show_ok():
    heading("OK")
    print()
    for dep in sort(ok):
        print("    ", dep['cbdep_dependency']['product'],
              dep['cbdep_dependency']['version'])


def show_drifted():
    if(len(drifted) > 0):
        heading("Drifted")
        for drift in sort(drifted):
            print()
            print("  " + drift['cbdep_dependency']['product'])
            print("  " + "-" * len(drift['cbdep_dependency']['product']))
            print(f"    Expected: {drift['cbdep_dependency']['version']}")
            print(
                f"       Found: {', '.join(drift['versions'])}")


def show_missing():
    if(len(missing) > 0):
        heading("Missing")
        print()
        for dep in missing:
            print("  ", dep['product'],
                  dep['version'])


# Load couchbase-server-black-duck-manifest.yaml and save important keys
bd_manifest = blackduck_manifest()
bd_components = bd_manifest['components']
bd_include_projects = bd_manifest.get('include-projects', [])

# Load manifest.cmake into useful dict
cbdeps_manifest = cbdeps()

# Initialize arrays of component names
ok = []
drifted = []
missing = []

# Iterate over all cbdeps from manifest.cmake
for cbdep_entry in cbdeps_manifest:
    cbdep = cbdep_entry['product']

    # If cbdep is in include-projects, it's OK.
    if cbdep in bd_include_projects:
        ok.append({"cbdep_dependency": cbdep_entry})
        continue

    # If cbdep isn't in 'components', save it in 'missing'
    if cbdep not in bd_components.keys():
        missing.append(cbdep_entry)
        continue

    # Ok, cbdep is in both manifets. Extract version(s) from bd manifest.
    if(isinstance(bd_components[cbdep], list)):
        bd_versions = bd_components[cbdep]
    else:
        bd_versions = bd_components[cbdep].get(
            'cbdeps-versions',
            bd_components[cbdep]['versions']
        )
    bd_versions = [short_version(str(x)) for x in bd_versions]

    # Ensure version from manifest.cmake is in BD versions.
    if (short_version(cbdep_entry['version']) not in bd_versions):
        # Version from manifest.cmake is NOT in BD manifest!
        if(bd_versions == []):
            # If BD manifest lists *no* versions, we're meant to ignore
            # the cbdep, so mark it OK
            ok.append({"cbdep_dependency": cbdep_entry})
        else:
            # BD manifest does not include the version specified by
            # manifest.cmake! Mark it drifted
            drifted.append({
                "cbdep_dependency": cbdep_entry,
                "versions": bd_versions
            })
    else:
        ok.append({"cbdep_dependency": cbdep_entry})

show_ok()
show_drifted()
show_missing()

exit(len(drifted) + len(missing) > 0)
