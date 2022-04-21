import argparse
import itertools
import json
import sys
import yaml

from jinja2 import Template
from pathlib import Path

def generate_filelist(product, release, version, build_num, template_file, debug=False):
    """
    Create a set of filenames for the given product, release, version
    and build number, using the specified template (which may be either
    a .json or a .yaml.j2)
    """

    with template_file.open() as tmpl:
        template = tmpl.read()

    if template_file.name.endswith(".json"):
        return generate_filelist_from_json(
            product, release, version, build_num, json.loads(template)
        )
    elif template_file.name.endswith(".yaml.j2"):
        return generate_filelist_from_jinja(
            product, release, version, build_num, Template(template), debug
        )
    else:
        print (f"Unrecognized extension on {template_file.name}!")
        sys.exit(1)

def generate_filelist_from_json(product, release, version, build_num, template):
    """
    Create a set of filenames for given set of build coordinates
    using a JSON template
    """
    req_files = set()
    prod_data = template[product]

    for pkg_name, pkg_data in prod_data['package'].items():
        try:
            rel_data = pkg_data['release'][release]
        except KeyError:
            print(f"Package '{pkg_name}' doesn't exist in configuration file "
                  f"for release '{release}'' of product '{product}'; ignoring...")
            continue

        # Find all the keys with lists as values
        params = [x for x in rel_data if isinstance(rel_data[x], list)]

        # For each platform supported for the release, take all the com-
        # binations (product) from the lists and generate a filename from
        # each combination along with other key information:
        #   - pkg_name (locally defined)
        #   - version and build_num, which are passed in
        #   - platform (retrieved from locals())
        #   - platform-specific entries (from the platform dictionary)
        #
        # The code makes heavy use of dictionary keyword expansion to populate
        # the filename template with the appropriate information
        for platform in rel_data['platform']:
            param_list = [rel_data[param] for param in params]

            for comb in itertools.product(*param_list):
                req_files.add(
                    rel_data['template'].format(
                        package=pkg_name, VERSION=version, BLD_NUM=build_num,
                        **locals(), **dict(zip(params, comb)),
                        **rel_data['platform'][platform]
                    )
                )

    return req_files

def generate_filelist_from_jinja(product, release, version, build_num, template, debug):
    """
    Create a set of filenames for a given set of build coordinates
    using a Jinja2 YAML template. The YAML file is expected to return
    a single list variable "filenames", and use input variables
    'product', 'release', 'version', and 'build_num'
    """

    try:
        version_tuple = tuple(map(int, version.split('.')))
    except ValueError:
        version_tuple = ()
    yaml_text = template.render(locals())
    if debug:
        print(f"\nGenerated YAML:\n\n{yaml_text}\n")
    filenames = yaml.safe_load(yaml_text)['filenames']
    if filenames is not None:
        return set(filenames)
    else:
        return set()

def main():
    """
    Test program for generate_filelist
    """

    parser = argparse.ArgumentParser(
        description='Test a check_builds template'
    )
    parser.add_argument('-p', '--product', help='Product name', required=True)
    parser.add_argument('-r', '--release', help='Release name', required=True)
    parser.add_argument('-v', '--version', help='Version', required=True)
    parser.add_argument('-b', '--bld_num', help='Build number', required=True)
    parser.add_argument('datafile', type=Path,
                        help='Template for determining build information')
    parser.add_argument('-d', '--debug', action="store_true",
                        help='Display generated yaml')
    args = parser.parse_args()

    if not args.datafile.exists():
        print (f"Datafile {args.datafile} does not exist")
        sys.exit(1)
    filelist = generate_filelist(
        args.product, args.release, args.version, args.bld_num,
        args.datafile, args.debug
    )
    for fname in filelist:
        print(fname)

if __name__ == '__main__':
    main()
