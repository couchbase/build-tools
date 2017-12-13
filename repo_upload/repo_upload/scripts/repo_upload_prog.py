"""
Program to manage updating the Couchbase Server package repositories
on AWS S3.

Currently the application supports the following types of repositories
(more may be added in the future):
    APT
    Yum

The enterprise and community builds are always handled separately,
along with each repository type.  For each it essentially builds a new
local repository on the system it's being run on, then syncs the files
to S3, allowing any new packages to now be available.
"""

import argparse
import configparser
import importlib
import logging
import sys


# Set up logging and handler
logger = logging.getLogger('repo_upload')
logger.setLevel(logging.INFO)


def main():
    """
    Parse the command line arguments, handle configuration setup,
    initialize for the correct repository type, then do the repository
    creation and upload to S3
    """

    parser = argparse.ArgumentParser(
        description='Upload APT or Yum package repository to S3'
    )
    parser.add_argument('-d', '--debug', action='store_true',
                        help='Enable debugging output')
    parser.add_argument('-c', '--config', dest='upload_config',
                        help='Configuration file for APT/Yum uploader',
                        default='repo_upload.ini')
    parser.add_argument('-r', '--repo-type', required=True,
                        choices=['apt', 'yum'],
                        help='Type of repository for upload')
    parser.add_argument('-e', '--edition', required=True,
                        choices=['community', 'enterprise'],
                        help='Version of software being uploaded')

    args = parser.parse_args()

    # Set logging to debug level on stream handler if --debug was set
    if args.debug:
        logger.setLevel(logging.DEBUG)

    # Check configuration file information
    upload_config = configparser.ConfigParser()
    upload_config.read(args.upload_config)

    if 'common' not in upload_config:
        logger.error(
            f'Invalid or unable to read config file {args.upload_config}'
        )
        sys.exit(1)

    common_info = upload_config['common']
    common_required_keys = [
        'gpg_file', 'gpg_key', 'releases_url', 'repo_path',
        's3_base_path', 's3_bucket'
    ]

    if any(key not in common_info for key in common_required_keys):
        logger.error(
            f'One of the following DB keys is missing in the config file:\n'
            f'    {", ".join(common_required_keys)}'
        )
        sys.exit(1)

    # Import only the specific module for the necessary repository type
    upload_module = f'repo_upload.repos.{args.repo_type}'
    upload_class = f'{args.repo_type.capitalize()}Repository'

    try:
        mod = importlib.import_module(upload_module)
    except ImportError as exc:
        logger.info(exc)
        logger.error(f'Module {upload_module} not found')
        sys.exit(1)

    upload = getattr(mod, upload_class)(args.edition, common_info)
    upload.update_repository()


if __name__ == '__main__':
    main()
