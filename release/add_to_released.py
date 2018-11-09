#!/usr/bin/env python3.6

import argparse
import configparser
import contextlib
import logging
import os
import pathlib
import shutil
import subprocess
import sys

import dulwich.porcelain as porcelain

import cbbuild.cbutil.git as cbutil_git


# Set up logging and handler
logger = logging.getLogger('add_to_released')
logger.setLevel(logging.INFO)

ch = logging.StreamHandler()
logger.addHandler(ch)

default_bytes_err_stream = getattr(sys.stderr, 'buffer', sys.stderr)


@contextlib.contextmanager
def cd(path):
    """Simple context manager to handle temporary directory change"""

    cwd = os.getcwd()

    try:
        os.chdir(path)
    except OSError:
        raise RuntimeError('Can not change directory to {}'.format(path))

    try:
        yield
    except Exception:
        logger.error(
            'Exception caught: {}'.format(' - '.join(sys.exc_info()[:2]))
        )
        raise RuntimeError('Failed code in new directory {}'.format(path))
    finally:
        os.chdir(cwd)


def main():
    """"""

    parser = argparse.ArgumentParser(
        description='Add a release manifest to the manifest repository'
    )
    parser.add_argument('-d', '--debug', action='store_true',
                        help='Enable debugging output')
    parser.add_argument('-c', '--config', dest='mf_config',
                        help='Configuration file for Git repositories',
                        default='manifest_config.ini')
    parser.add_argument('product', help='Name of product')
    parser.add_argument('release', help='Release name for product')
    parser.add_argument('version', help='Version for product')
    parser.add_argument('build_num', help='Build number for release')

    args = parser.parse_args()
    product = args.product
    release = args.release
    version = args.version
    build_num = args.build_num

    # Set logging to debug level on stream handler if --debug was set
    if args.debug:
        logger.setLevel(logging.DEBUG)

    # Parse and validate configuration file
    mf_config = configparser.ConfigParser()
    mf_config.read(args.mf_config)

    if 'main' not in mf_config.sections():
        logger.error(
            'Invalid or unable to read config file "{}"'.format(mf_config)
        )
        sys.exit(1)

    try:
        mf_url = mf_config.get('main', 'manifest_repo_url')
        bmf_url = mf_config.get('main', 'build_manifests_repo_url')
        push_url = mf_config.get('main', 'push_manifest_url')
    except configparser.NoOptionError:
        logger.error(
            'One of the options is missing from the config file: '
            'manifest_repo_url, build_manifests_repo_url, push_manifest_url.'
            '\nAborting...'
        )
        sys.exit(1)

    # Set up working directory paths
    top_dir = pathlib.Path('add_release').resolve()
    mf_dir = top_dir / 'manifest'
    bmf_dir = top_dir / 'build-manifests'

    if top_dir.exists():
        shutil.rmtree(top_dir)

    top_dir.mkdir()

    with cd(top_dir):
        # Clone the manifest and build-manifests repositories
        cbutil_git.checkout_repo(mf_dir, mf_url, bare=False)
        cbutil_git.checkout_repo(bmf_dir, bmf_url, bare=False)

        # Acquire build manifest for given release from build-manifests
        # based on given input; currently shells out to Git to determine
        # the necessary information and retrieve the manifest
        with cd(bmf_dir):
            msg_regex = f'{product} .* {version}-{build_num}'
            sha = subprocess.run(['git', 'log', '--format=%H', '--grep',
                                  msg_regex], check=True,
                                 stdout=subprocess.PIPE).stdout.strip()

            path = f'{product}/{release}/{version}.xml'
            manifest = subprocess.run(
                ['git', 'show', f'{sha.decode()}:{path}'],
                check=True, stdout=subprocess.PIPE).stdout

        # Copy manifest to build-manifests into the proper directory
        # under the 'released' subdirectory, then commit and push change
        with cd(mf_dir):
            rel_dir = mf_dir / 'released' / product
            rel_dir.mkdir(parents=True, exist_ok=True)
            rel_file = rel_dir / f'{version}.xml'

            with open(rel_file, 'wb') as fh:
                fh.write(manifest)
                fh.write(b'\n')

            porcelain.add(paths=[rel_file])
            porcelain.commit(
                message=f"Add {version} release for {product} into "
                        f"'released' directory".encode('utf-8'),
                committer=b'Couchbase Build Team <build-team@couchbase.com>',
                author=b'Couchbase Build Team <build-team@couchbase.com>'
            )
            porcelain.push(
                mf_dir, push_url, b'refs/heads/master:refs/heads/master'
            )


if __name__ == '__main__':
    main()
