#!/usr/bin/env python3
''' Script to update Carthage JSON provisioning file for CBL releases
'''

import argparse
import json
import sys
from collections import OrderedDict


def parse_json_file(file):
    '''
    Parse content of input JSON file, return data dictionary
    '''
    try:
        with open(file) as content:
            try:
                data = json.load(content, object_pairs_hook=OrderedDict)
            except json.JSONDecodeError:
                print('Invalid JSON content!')
                sys.exit(1)
    except IOError:
        print(f'Could not open file: {file}')
        sys.exit(1)
    return data


def update_json_file(args):
    '''
    Update Carthage JSON file with CBL release version on S3
    '''
    cbl_s3_url = f'https://packages.couchbase.com/releases/{args.product}'
    carthage_pkg_name = args.carthage

    data_dict = parse_json_file(args.file)
    data_dict[args.version] = f'{cbl_s3_url}/{args.version}/{carthage_pkg_name}'

    try:
        with open(args.file, mode='w') as f:
            try:
                f.write(json.dumps(data_dict, indent=4))
            except json.JSONDecodeError:
                print('Invalid JSON output!')
                sys.exit(1)
    except IOError:
        print(f'Cannot write to file: {args.file}')
        sys.exit(1)


def parse_args():
    parser = argparse.ArgumentParser(
        description='Publish Carthage Provision File on S3\n\n')
    parser.add_argument('--product', '-p', choices=[
                        'couchbase-lite-ios', 'couchbase-lite-vector-search'], help='Product Name')
    parser.add_argument('--version', '-v', help='Carthage Version',
                        required=True)
    parser.add_argument('--file', '-f', help='JSON file', required=True)
    parser.add_argument('--carthage', '-c',
                        help='Carthage Package Name', required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    update_json_file(args)


if __name__ == '__main__':
    main()
