#!/usr/bin/python3

import re
import yaml

ok = []
drifted = []
missing = []


def heading(text):
    print()
    print("*" * (len(text)+4))
    print(f"* {text} *")
    print("*" * (len(text)+4))


def short_version(text):
    return re.sub('\.0$', '', re.sub('^(v|V)', '', text))


def product_and_version(words):
    # Retrieve product and version from a DECLARE_DEP line in manifest.cmake
    product = words[1][1:]
    version = re.sub("(-cb[0-9]+|-couchbase)", '',
                     words[4] if(words[2] == "V2") else words[3])
    return {"product": product, "version": version}


def cbdeps():
    with open('tlm/deps/manifest.cmake') as f:
        # return [{product,version}, ...] for all DECLARE_DEP lines in manifest
        return [dict(t) for t in {tuple(d.items()) for d in map(product_and_version, [
            line.split() for line in f.readlines() if line.startswith("DECLARE_DEP")
        ])}]


def blackduck_deps():
    with open('tlm/deps/couchbase-server-black-duck-manifest.yaml') as f:
        return yaml.safe_load(f)['components']


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


blackduck = blackduck_deps()

for cbdep_dependency in [dep for dep in cbdeps() if dep['product'] not in blackduck.keys()]:
    missing.append(cbdep_dependency)

for cbdep_dependency in [dep for dep in cbdeps() if dep['product'] in blackduck.keys()]:
    cbdeps_versions = []
    if(isinstance(blackduck[cbdep_dependency['product']], dict)):
        if 'cbdeps-versions' in blackduck[cbdep_dependency['product']]:
            cbdeps_versions = [
                short_version(str(x)) for x in blackduck[cbdep_dependency['product']]['cbdeps-versions']]
        else:
            cbdeps_versions = [
                short_version(str(x)) for x in blackduck[cbdep_dependency['product']]['versions']]
    else:
        cbdeps_versions = [
            short_version(str(x)) for x in blackduck[cbdep_dependency['product']]]

    if (short_version(cbdep_dependency['version']) not in cbdeps_versions):
        if(cbdeps_versions == []):
            ok.append({"cbdep_dependency": cbdep_dependency,
                   "versions": cbdeps_versions})
        else:
            drifted.append({"cbdep_dependency": cbdep_dependency,
                            "versions": cbdeps_versions})
    else:
        ok.append({"cbdep_dependency": cbdep_dependency,
                   "versions": cbdeps_versions})

show_ok()
show_drifted()
show_missing()

exit(len(drifted) + len(missing) > 0)
