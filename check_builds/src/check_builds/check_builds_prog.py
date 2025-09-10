"""
Program to check for missing builds in latestbuilds for each existing
product-release-version combination.  The program steps through the build
documents in the build database, determines which haven't been checked
yet and then generates a necessary list of files that should exist, based
on data stored in a JSON file.  The build documents are updated as needed
so things aren't repeatedly checked.  Will email on the first check of a
known failure.
"""

import argparse
import configparser
import json
import logging
import os
import smtplib
import subprocess
import sys
import time

from email.mime.text import MIMEText
from pathlib import Path
from .util import generate_filelist

import cbbuild.database.db as cbutil_db


# Set up logging and handler
logger = logging.getLogger('check_builds.scripts.check_builds')
logger.setLevel(logging.INFO)

ch = logging.StreamHandler()
logger.addHandler(ch)

# Echo command being executed - helpful for debugging
def run(cmd, **kwargs):
    print("++", *cmd)
    return subprocess.run(cmd, **kwargs)


def generate_mail_body(lb_url, missing):
    """"""

    body = f'Refer to {lb_url} to view existing files\n\n'
    body += f'\nMissing files:\n\n'
    body += f'\n'.join([f'    {file}' for file in sorted(list(missing))])
    body += f'\n'

    return body


def send_email(smtp_server, receivers, message, dryrun):
    """Simple method to send email"""

    msg = MIMEText(message['body'])

    msg['Subject'] = message['subject']
    msg['From'] = 'build-team@couchbase.com'
    msg['To'] = ', '.join(receivers)

    if dryrun:
        logger.info(f"Not sending email (dry run):\n {msg.as_string()}")
        return

    try:
        smtp = smtplib.SMTP(smtp_server, 25)
        smtp.sendmail(
            'build-team@couchbase.com',
            receivers,
            msg.as_string()
        )
    except smtplib.SMTPException as exc:
        logger.error('Mail server failure: %s', exc)
    finally:
        smtp.quit()


def main():
    """
    Parse the command line arguments, handle configuration setup,
    load in the product data and step through the build documents
    in the build database to determine which have completed builds
    or not
    """

    util_dir = Path(__file__).parent.parent.parent.parent / "utilities"

    parser = argparse.ArgumentParser(
        description='Update documents in build database'
    )
    parser.add_argument('-c', '--config', dest='check_build_config',
                        help='Configuration file for build database loader',
                        default='check_builds.ini')
    parser.add_argument('-n', '--dryrun', action='store_true',
                        help="Only check, don't update database or send email")
    parser.add_argument('-v', '--verbose', action='store_true',
                        help="Enable additional debug output")
    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)
    dryrun = args.dryrun
    metadata_dir = Path.cwd() / 'repos' / 'product-metadata'
    run([
        util_dir / "clean_git_clone",
        "https://github.com/couchbase/product-metadata",
        metadata_dir
    ])

    # Check configuration file information
    check_build_config = configparser.ConfigParser()
    check_build_config.read(args.check_build_config)

    if any(key not in check_build_config
           for key in ['build_db', 'missing_builds']):
        logger.error(
            f'Invalid or unable to read config file {args.check_build_config}'
        )
        sys.exit(1)

    db_info = check_build_config['build_db']
    db_required_keys = ['db_uri', 'username', 'password']

    if any(key not in db_info for key in db_required_keys):
        logger.error(
            f'One of the following DB keys is missing in the config file:\n'
            f'    {", ".join(db_required_keys)}'
        )
        sys.exit(1)

    miss_info = check_build_config['missing_builds']
    miss_required_keys = [
        'receivers', 'lb_base_dir', 'lb_base_url', 'smtp_server', 'delay'
    ]

    if any(key not in miss_info for key in miss_required_keys):
        logger.error(
            f'One of the following DB keys is missing in the config file:\n'
            f'    {", ".join(miss_required_keys)}'
        )
        sys.exit(1)

    # Find builds to check
    db = cbutil_db.CouchbaseDB(db_info)
    builds = db.query_documents(
        'build',
        where_clause="ifmissingornull(metadata.builds_complete, 'n/a')='n/a'"
    )

    # Go through builds and based on age and whether certain metadata
    # values (builds_complete and email_notification) are set, determine
    # proper course of action.  The basic process is as follows:
    #   - Get age of build
    #   - If build age is over 28 days old, simply mark as unknown
    #     (files already gone from latestbuilds)
    #   - If the product isn't in the product config data, skip
    #   - Generate necessary file list, then get current file list from
    #     latestbuilds (mounted via NFS)
    #   - Check to see if any files in needed list aren't in current list:
    #      - If not, mark build complete and continue
    #      - Else if there are and build age is over `delay` hours, check to
    #        see if email's been sent previously and send notification
    #        if not, marking email as sent
    #      - And if there are and build age is also over 12 hours, mark
    #        as incomplete and continue
    for build in builds:
        build_age = int(time.time()) - build.timestamp

        if build_age > 28 * 24 * 60 * 60:  # 28 days
            dryrun or build.set_metadata('builds_complete', 'unknown')
            continue

        template_dir = metadata_dir / build.product / "check_builds"
        if not template_dir.exists():
            logger.debug(f"Skipping build for unknown product {build.product}")
            continue

        prodver_path = f'{build.product}/{build.release}/{build.build_num}'
        lb_dir = f'{miss_info["lb_base_dir"]}/{prodver_path}/'
        lb_url = f'{miss_info["lb_base_url"]}/{prodver_path}/'

        templates = list(
            filter(
                lambda x: x.name.endswith(('.yaml.j2', '.json')),
                template_dir.glob("pkg_data.*")
            )
        )
        if len(templates) < 1:
            logger.error(f"Product {build.product} has no pkg_data templates")
            sys.exit(1)
        if len(templates) > 1:
            logger.error(f"Found multiple possible pkg_data files for {build.product}!")
            sys.exit(1)
        logger.debug(f"Using template {templates[0]} for {build.product}")

        logger.info(f"***** Checking {build.product} {build.release} build {build.version}-{build.build_num} ({build_age} seconds old)")

        needed_files = generate_filelist(
            build.product, build.release, build.version, build.build_num,
            templates[0]
        )
        try:
            existing_files = set(os.listdir(lb_dir))
        except FileNotFoundError:
             existing_files = set()
        missing_files = list(needed_files.difference(existing_files))

        if not missing_files:
            logger.info("All expected files found - build complete!")
            dryrun or build.set_metadata('builds_complete', 'complete')
            continue

        hours = int(miss_info['delay'])
        if build_age > hours * 60 * 60:
            logger.info(f"Still incomplete after {hours} hours; missing files:")
            for missing in missing_files:
                logger.info(f"    - {missing}")
            if not build.metadata.setdefault('email_notification', False):
                curr_bld = \
                    f'{build.product}-{build.version}-{build.build_num}'
                message = {
                    'subject': f'Build {curr_bld} not complete after {hours} hours',
                    'body': generate_mail_body(lb_url, missing_files)
                }
                receivers = miss_info['receivers'].split(',')
                send_email(miss_info['smtp_server'], receivers, message, dryrun)
                dryrun or build.set_metadata('email_notification', True)
            else:
                logger.info("Email previously sent")
        else:
            logger.info(f"Incomplete but less than {hours} hours old")

        if build_age > 12 * 60 * 60:  # 12 hours
            logger.info("Build incomplete after 12 hours - marking incomplete")
            dryrun or build.set_metadata('builds_complete', 'incomplete')


if __name__ == '__main__':
    main()
