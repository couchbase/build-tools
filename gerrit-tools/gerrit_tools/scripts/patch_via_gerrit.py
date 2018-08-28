#!/usr/bin/env python

"""
Basic program to apply a set of patches from various Gerrit reviews
based on user criteria to a repo sync area (for purposes of testing)

The current logic is to apply the patches in order of the Gerrit review
IDs (e.g. 94172) once all relevant reviews have been determined
"""

import argparse
import ConfigParser
import contextlib
import logging
import os
import os.path
import subprocess
import sys
import xml.etree.ElementTree as EleTree

import requests.exceptions

from pygerrit2 import GerritRestAPI, HTTPBasicAuth


# Set up logging and handler
logger = logging.getLogger('patch_via_gerrit')
logger.setLevel(logging.INFO)

ch = logging.StreamHandler()
logger.addHandler(ch)


@contextlib.contextmanager
def cd(path):
    """Simple context manager to handle temporary directory change"""

    cwd = os.getcwd()

    try:
        os.chdir(path)
    except OSError:
        raise RuntimeError('Can not change directory')

    try:
        yield
    except Exception:
        logger.error('Exception caught: %s', sys.exc_info()[0])
        raise RuntimeError('Failed code in new directory')
    finally:
        os.chdir(cwd)


class GerritChange(object):
    """Encapsulation of relevant information for a given Gerrit review"""

    def __init__(self, data):
        """
        Initialize with key information for a Gerrit review, including
        information about related parents
        """

        self.status = data['status']
        self.project = data['project']
        self.change_id = data['change_id']
        self.topic = data.get('topic')
        self.curr_revision = data['current_revision']
        revisions_info = data['revisions'][self.curr_revision]
        self.parents = [
            p['commit'] for p in revisions_info['commit']['parents']
        ]
        fetch_info = revisions_info['fetch']

        if 'anonymous http' in fetch_info:
            self.patch_command = \
                fetch_info['anonymous http']['commands']['Cherry Pick']
        else:  # only other option is SSH
            self.patch_command = fetch_info['ssh']['commands']['Cherry Pick']


class GerritPatches(object):
    """
    Determine all relevant patches to apply to a repo sync based on
    a given set of initial parameters, which can be a set of one of
    the following:
        - review IDs
        - change IDs
        - topics

    The resulting data will include the necessary patch commands to
    be applied to the repo sync
    """

    def __init__(self, gerrit_url, user, passwd):
        """Initial Gerrit connection and set base options"""

        auth = HTTPBasicAuth(user, passwd)
        self.rest = GerritRestAPI(url=gerrit_url, auth=auth)
        self.base_options = [
            'CURRENT_REVISION', 'CURRENT_COMMIT', 'DOWNLOAD_COMMANDS'
        ]
        self.seen_reviews = set()

    def query(self, query_string, options=None):
        """
        Get results from Gerrit for a given query string, returning
        a dictionary keyed off the relevant review IDs, the values
        being a special object containing all relevant information
        about a review
        """

        if options is None:
            options = self.base_options

        opt_string = '&o='.join([''] + options)
        data = dict()

        try:
            results = self.rest.get(query_string + opt_string)
        except requests.exceptions.HTTPError as exc:
            raise RuntimeError(exc)
        else:
            for result in results:
                num_id = result['_number']
                data[num_id] = GerritChange(result)

        return data

    def get_changes_via_review_id(self, review_id):
        """Find all reviews for a given review ID"""

        return self.query('/changes/?q={}'.format(review_id))

    def get_changes_via_change_id(self, change_id):
        """Find all reviews for a given change ID"""

        return self.query('/changes/?q=change:{}'.format(change_id))

    def get_changes_via_topic_id(self, topic):
        """Find all reviews for a given topic"""

        return self.query('/changes/?q=topic:{}'.format(topic))

    def get_open_parents(self, review):
        """Find all open parent reviews for a given review"""

        reviews = dict()

        if not review.parents:
            return reviews

        # Search recursively up via the parents until no more
        # open reviews are found
        for parent in review.parents:
            p_review = self.query(
                '/changes/?q=status:open+commit:{}'.format(parent)
            )

            if not p_review:
                continue

            p_review_id = p_review.keys()[0]
            reviews.update(p_review)
            reviews.update(self.get_open_parents(p_review[p_review_id]))

        return reviews

    def get_reviews(self, initial_args, id_type):
        """
        From an initial set of parameters (review IDs, change IDs or
        topics), determine all relevant open reviews that will need
        to be applied to a repo sync via patching
        """

        all_reviews = dict()
        stack = list()

        # Generate initial set of reviews from the initial set
        # of parameters, generating the stack (list of review IDs)
        # from the results
        for initial_arg in initial_args:
            reviews = getattr(
                self, 'get_changes_via_{}_id'.format(id_type)
            )(initial_arg)

            stack.extend([r_id for r_id in reviews.keys()])

        # From the stack, check each entry and add to the final set
        # of reviews if not already there, keeping track of which
        # have been seen so far.  For each review, also look for any
        # related reviews via change ID and topic, along with any
        # still open parents, adding to the stack as needed.  All
        # relevant reviews will have been found once the stack is empty.
        while stack:
            review_id = stack.pop()
            reviews = self.get_changes_via_review_id(review_id)

            for new_id, review in reviews.iteritems():
                if new_id in self.seen_reviews:
                    continue

                all_reviews[new_id] = review
                self.seen_reviews.add(new_id)

                change_reviews = self.get_changes_via_change_id(
                    review.change_id
                )
                stack.extend(
                    [r_id for r_id in change_reviews.keys()
                     if r_id not in self.seen_reviews]
                )

                if review.topic is not None:
                    topic_reviews = self.get_changes_via_topic_id(
                        review.topic
                    )
                    stack.extend(
                        [r_id for r_id in topic_reviews.keys()
                         if r_id not in self.seen_reviews]
                    )

                stack.extend(
                    [r_id for r_id in self.get_open_parents(review)
                     if r_id not in self.seen_reviews]
                )

        return all_reviews


def main():
    """
    Parse the arguments, verify the repo sync exists, read and validate
    the configuration file, then determine all the needed Gerrit patches
    and apply them to the repo sync
    """

    parser = argparse.ArgumentParser(
        description='Patch repo sync with requested Gerrit reviews'
    )
    parser.add_argument('-c', '--config', dest='gerrit_config',
                        help='Configuration file for patching via Gerrit',
                        default='patch_via_gerrit.ini')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('-r', '--review-id', dest='review_ids', default=[],
                       type=int, action='append', help='review ID to apply')
    group.add_argument('-g', '--change-id', dest='change_ids', default=[],
                       action='append', help='change ID to apply')
    group.add_argument('-t', '--topic', dest='topics', default=[],
                       action='append', help='topic to apply')
    parser.add_argument('-s', '--source', dest='repo_source', required=True,
                        help='Location of the repo sync checkout')

    args = parser.parse_args()

    if not os.path.isdir(args.repo_source):
        logger.error(
            'Path for repo sync checkout doesn\'t exist.  Aborting...'
        )
        sys.exit(1)

    gerrit_config = ConfigParser.ConfigParser()
    gerrit_config.read(args.gerrit_config)

    if 'main' not in gerrit_config.sections():
        logger.error(
            'Invalid or unable to read config file "{}"'.format(
                args.gerrit_config
            )
        )
        sys.exit(1)

    try:
        gerrit_url = gerrit_config.get('main', 'gerrit_url')
        user = gerrit_config.get('main', 'username')
        passwd = gerrit_config.get('main', 'password')
    except ConfigParser.NoOptionError:
        logger.error(
            'One of the options is missing from the config file: '
            'gerrit_url, username, password.  Aborting...'
        )
        sys.exit(1)

    # Initialize class to allow connection to Gerrit URL, determine
    # type of starting parameters and then find all related reviews
    gerrit_patches = GerritPatches(gerrit_url, user, passwd)

    if args.review_ids:
        id_type = 'review'
        review_ids = args.review_ids
    elif args.change_ids:
        id_type = 'change'
        review_ids = args.change_ids
    else:
        id_type = 'topic'
        review_ids = args.topics

    reviews = gerrit_patches.get_reviews(review_ids, id_type)

    # Now patch the repo sync with the list of patch commands
    try:
        with cd(args.repo_source):
            mf = EleTree.parse('.repo/manifest.xml')

            for review_id in sorted(reviews.keys()):
                review = reviews[review_id]
                proj_info = mf.find(
                    './/project[@name="{}"]'.format(review.project)
                )

                try:
                    with cd(proj_info.attrib.get('path', review.project)):
                        subprocess.check_call(review.patch_command,
                                              shell=True)
                except subprocess.CalledProcessError:
                    raise RuntimeError(
                        'Patch for review %d failed' % (review_id,)
                    )
    except RuntimeError as exc:
        logger.error(exc)
        sys.exit(1)


if __name__ == '__main__':
    main()
