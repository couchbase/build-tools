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
import itertools
import json
import logging
import os
import smtplib
import sys
import time

from email.mime.text import MIMEText

import cbbuild.cbutil.db as cbutil_db


# Set up logging and handler
logger = logging.getLogger('check_builds.scripts.check_builds')
logger.setLevel(logging.INFO)

ch = logging.StreamHandler()
logger.addHandler(ch)


def generate_filelist(product, release, version, build_num, conf_data):
    """
    Create a set of filenames for the given product, release, version
    and build number from the configuration file data
    """

    try:
        prod_data = conf_data[product]
    except KeyError:
        print(f"Product {product} doesn't exist in configuration file")
        sys.exit(1)

    req_files = set()

    for pkg_name, pkg_data in prod_data['package'].items():
        try:
            rel_data = pkg_data['release'][release]
        except KeyError:
            print(f"Release {release} of package {pkg_name} for product "
                  f"{product} doesn't exist in configuration file")
            sys.exit(1)

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


def generate_mail_body(lb_url, missing):
    """"""

    body = f'Refer to {lb_url} to view existing files\n\n'
    body += f'\nMissing files:\n\n'
    body += f'\n'.join([f'    {file}' for file in sorted(list(missing))])
    body += f'\n'

    return body


def send_email(smtp_server, receivers, message):
    """Simple method to send email"""

    msg = MIMEText(message['body'])

    msg['Subject'] = message['subject']
    msg['From'] = 'build-team@couchbase.com'
    msg['To'] = ', '.join(receivers)

    smtp = smtplib.SMTP(smtp_server, 25)

    try:
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

    parser = argparse.ArgumentParser(
        description='Update documents in build database'
    )
    parser.add_argument('-c', '--config', dest='check_build_config',
                        help='Configuration file for build database loader',
                        default='check_builds.ini')
    parser.add_argument('datafiles', nargs='+',
                        help='One or more data files for determining build '
                             'information')

    args = parser.parse_args()

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
        'receivers', 'lb_base_dir', 'lb_base_url', 'smtp_server'
    ]

    if any(key not in miss_info for key in miss_required_keys):
        logger.error(
            f'One of the following DB keys is missing in the config file:\n'
            f'    {", ".join(miss_required_keys)}'
        )
        sys.exit(1)

    # Load in configuration data
    conf_data = dict()

    for datafile in args.datafiles:
        try:
            conf_data.update(json.load(open(datafile)))
        except FileNotFoundError:
            logger.error(f"Configuration file '{datafile}' missing")
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
    #      - Else if there are and build age is over 2 hours, check to
    #        see if email's been sent previously and send notification
    #        if not, marking email as sent
    #      - And if there are and build age is also over 12 hours, mark
    #        as incomplete and continue
    for build in builds:
        build_age = int(time.time()) - build.timestamp

        if build_age > 28 * 24 * 60 * 60:  # 28 days
            build.set_metadata('builds_complete', 'unknown')
            continue

        if build.product not in conf_data:
            continue

        prodver_path = f'{build.product}/{build.release}/{build.build_num}'
        lb_dir = f'{miss_info["lb_base_dir"]}/{prodver_path}/'
        lb_url = f'{miss_info["lb_base_url"]}/{prodver_path}/'

        needed_files = generate_filelist(
            build.product, build.release, build.version, build.build_num,
            conf_data
        )
        existing_files = set(os.listdir(lb_dir))
        missing_files = list(needed_files.difference(existing_files))

        if not missing_files:
            build.set_metadata('builds_complete', 'complete')
            continue

        if build_age > 2 * 60 * 60:  # 2 hours
            if not build.metadata.setdefault('email_notification', False):
                curr_bld = \
                    f'{build.product}-{build.version}-{build.build_num}'
                message = {
                    'subject': f'Build {curr_bld} not complete after 2 hours',
                    'body': generate_mail_body(lb_url, missing_files)
                }
                receivers = miss_info['receivers'].split(',')
                send_email(miss_info['smtp_server'], receivers, message)
                build.set_metadata('email_notification', True)

        if build_age > 12 * 60 * 60:  # 12 hours
            build.set_metadata('builds_complete', 'incomplete')


if __name__ == '__main__':
    main()
