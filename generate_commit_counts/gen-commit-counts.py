#!/usr/bin/env python3

import argparse
import base64
import configparser
import datetime
from datetime import date, timedelta
import json
import os
import re
import sys

import collections
from collections import defaultdict
from email.message import EmailMessage
import smtplib
from requests.exceptions import RequestException
import urllib.request
import urllib.error
import urllib.parse

from dateutil import tz
from pygerrit2 import GerritRestAPI, HTTPBasicAuth

email_file = 'email.txt'


class ConfigParse:
    def __init__(self, args):
        self.gerrit_user_emails = list()
        self.git_users = defaultdict()
        self.conf = args.conf
        self.gerrit_config = args.gerrit_config
        self.git_config = args.git_config
        self.date_range = int(args.date_range)
        self.recipient = args.recipient
        self.smtp_server = None
        self.git_url = None
        self.git_user = None
        self.git_passwd = None
        self.gerrit_auth = None
        self.gerrit_rest = None
        self.read_projects_config()

    def read_projects_config(self):
        """
        Read projects config file to determine Gerrit or Git users info.
        Return list of Gerrit users (me@couchbase.com)
        Return dictionary of Git users (git_login_id:full_name)
        """
        config = configparser.ConfigParser(allow_no_value=True)
        if config.read(self.conf):
            for section_name in config.sections():
                if section_name == 'gerrit-users':
                    self.gerrit_user_emails = config.options(section_name)
                elif section_name == 'git-users':
                    for gid, gname in config.items(section_name):
                        self.git_users[gid] = gname
                elif section_name == 'smtp_server':
                    self.smtp_server = config.options(section_name)[0]

    def read_git_config(self):
        """
            Read Git config and return git_url, git_user and git_passwd
        """
        git_config = configparser.ConfigParser()
        git_config.read(self.git_config)

        if 'main' not in git_config.sections():
            print(
                'Invalid or unable to read config file "{}"'.format(
                    self.git_config
                )
            )
            sys.exit(1)
        try:
            self.git_url = git_config.get('main', 'git_url')
            self.git_user = git_config.get('main', 'username')
            self.git_passwd = git_config.get('main', 'password')
        except configparser.NoOptionError:
            print(
                'One of the options is missing from the config file: '
                'git_url, username, password.  Aborting...'
            )
            sys.exit(1)

    def read_gerrit_config(self):
        """
            Read Gerrit config and return Gerrit Rest, Gerrit authentication object
        """
        gerrit_config = configparser.ConfigParser()
        gerrit_config.read(self.gerrit_config)

        if 'main' not in gerrit_config.sections():
            print(
                'Invalid or unable to read config file "{}"'.format(
                    self.gerrit_config
                )
            )
            sys.exit(1)
        try:
            gerrit_url = gerrit_config.get('main', 'gerrit_url')
            user = gerrit_config.get('main', 'username')
            passwd = gerrit_config.get('main', 'password')
        except configparser.NoOptionError:
            print(
                'One of the options is missing from the config file: '
                'gerrit_url, username, password.  Aborting...'
            )
            sys.exit(1)

        # Initialize class to allow connection to Gerrit URL, determine
        # type of starting parameters and then find all related reviews
        self.gerrit_auth = HTTPBasicAuth(user, passwd)
        self.gerrit_rest = GerritRestAPI(url=gerrit_url, auth=self.gerrit_auth)


class GenerateGitCommits():
    """
        Generate Git commit counts from a given date range using Git API
        TODO: Remove hard coded git repo (mobile-testkit), getting repo per git user
    """

    def __init__(self, args):
        configObj = ConfigParse(args)
        configObj.read_git_config()
        self.git_users = configObj.git_users
        self.git_url = configObj.git_url
        self.git_user = configObj.git_user
        self.git_passwd = configObj.git_passwd
        self.date_range = configObj.date_range
        self.gitrepos = {'mobile-testkit': 'couchbaselabs'}

    def send_request(self, post_data=None):
        if post_data is not None:
            post_data = json.dumps(post_data).encode("utf-8")

        currdate = datetime.datetime.utcnow()
        date_range = (currdate - timedelta(days=self.date_range))
        date_range_str = date_range.strftime("%Y-%m-%d") + 'T00:00:00Z'
        full_url = self.git_url + "/repos/%s/%s/commits?since=%s" % (self.git_org, self.git_repo, date_range_str)
        req = urllib.request.Request(full_url, post_data)

        req.add_header("Authorization", b"Basic " + base64.urlsafe_b64encode(self.git_user.encode("utf-8") + b":" + self.git_passwd.encode("utf-8")))

        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")

        try:
            response = urllib.request.urlopen(req)
            json_data = response.read()
        except urllib.error.HTTPError as error:

            error_details = error.read()
            error_details = json.loads(error_details.decode("utf-8"))

            if error.code in http_error_messages:
                sys.exit(http_error_messages[error.code])
            else:
                error_message = "ERROR: There was a problem with git query.\n%s %s" % (error.code, error.reason)
                if 'message' in error_details:
                    error_message += "\nDETAILS: " + error_details['message']
                sys.exit(error_message)
        # Also write to git_debug.json
        with open('git_debug.json', 'w') as fl:
            fl.write(json_data.decode("utf-8"))
        return json.loads(json_data.decode("utf-8"))

    def get_time(self, input_time):
        indate = str(input_time).split('.')
        input_date = datetime.datetime.strptime(indate[0], '%Y-%m-%dT%H:%M:%SZ')
        return input_date

    def generate_gitid_data(self, gid, item, data_dict):
        '''
            Function to take git_login_id, item value and a dictionary
            return the dictionary of git_login_id and item value
        '''
        if gid in data_dict:
            data_dict[gid].append(item)
        else:
            data_dict[gid] = [item]
        return data_dict

    def get_git_commits_count(self):

        for repo in self.gitrepos:
            self.git_org = self.gitrepos[repo]
            self.git_repo = repo
            self.git_unknown_users = defaultdict()

            data = self.send_request()

            currdate = datetime.datetime.utcnow()
            commits_counts = defaultdict()
            commits_repos = defaultdict(set)
            commits_message = defaultdict()
            repos = list()

            for i in data:
                if i["author"] != None:  # author's login id is present
                    git_creds = str(i["author"]["id"])
                elif i["commit"]["author"]["name"]:  # check author's name
                    g_name = i["commit"]["author"]["name"]
                    # Find Git's author login id with a matching author's name
                    git_author_id = [git_id for (git_id, git_name) in self.git_users.items() if g_name in git_name]
                    git_creds = git_author_id[0]
                else:
                    print(f'Cannot find valid author for this commit: {i["sha"]} - {i["html_url"]}')
                    git_unknown_users[i["sha"]].add(i["html_url"])

                if git_creds:
                    # Generate commit counts dictionary
                    self.generate_gitid_data(git_creds, i["sha"], commits_counts)
                    strip_repo_url = re.sub(r"https:\/\/github\.com\/(.*)\/commit.*$", r"\1", i["html_url"])
                    # Generate repos
                    repos.append(strip_repo_url) if strip_repo_url not in repos else repos
                    commits_repos[git_creds].add(strip_repo_url)
                    # Generate commit messages
                    self.generate_gitid_data(git_creds, i["sha"] + ' -- ' + i["commit"]["message"], commits_message)

            # Generate count and report
            # Dump the result to email.txt file: # Todo: template email
            with open(email_file, 'a') as fl:
                patt80 = "=" * (80)
                patt35 = "=" * (35)
                fl.write(f"\n{patt80}\n")
                fl.write(f"\n{patt35} GIT Count {patt35}\n")
                fl.write(f"\n{patt80}\n\n")
                fl.write(f'\nDate Range - {self.date_range}')
                fl.write(f'\nFrom Date (UTC): {currdate}')
                fl.write(f'\nTo Date (UTC): {(currdate - timedelta(self.date_range))}')
                fl.write('\n')
                for git_author_id, git_author_name in self.git_users.items():
                    if git_author_id in commits_counts.keys():
                        total_commits = len(commits_counts[git_author_id])
                        commit_messages = commits_message[git_author_id]
                        repos = commits_repos[git_author_id]
                    else:
                        total_commits = 0
                        commit_messages = ''
                        repos = ''

                    # write/print the result
                    fl.write(f'\nUser: {git_author_name}')
                    fl.write(f'\nTotal Commit(s): {total_commits}')
                    fl.write('\nRepos(s): ' + '\n'.join(map(str, repos)))
                    fl.write('\nCommit Messages:\n')
                    fl.write('\n'.join(map(str, commit_messages)))
                    fl.write('\n')

            # Report all unknown matching commits
            if self.git_unknown_users:
                print()
                print('WARNING!  Found unknown commits:')
                print(f'Details: {self.git_unknown_users}')
                print()
                sys.exit(1)

    def git_commit_caller(self):
        """ Driver function call for generate commits program"""
        self.get_git_commits_count()


class GenerateGerritCommits():
    """
        Generate commit counts from a given date range using Gerrit API
    """

    def __init__(self, args):
        configObj = ConfigParse(args)
        configObj.read_gerrit_config()
        self.gerrit_user_accounts = defaultdict()
        self.gerrit_rest = configObj.gerrit_rest
        self.gerrit_auth = configObj.gerrit_auth
        self.date_range = configObj.date_range
        self.gerrit_user_emails = configObj.gerrit_user_emails
        self.smtp_server = configObj.smtp_server
        self.recipient = configObj.recipient

    def generate_gerrit_user_name(self):
        rest = self.gerrit_rest
        for u_email in self.gerrit_user_emails:
            try:
                query = u_email
                user_data = rest.get("/accounts/?suggest&q=%s" % query)
                for acc in user_data:
                    for key, value in acc.items():
                        if key == 'email':
                            user_email = value
                        elif key == 'name':
                            user_name = value
                    if user_name:
                        self.gerrit_user_accounts[user_email] = user_name
                    else:
                        self.gerrit_user_accounts[user_email] = user_email
            except RequestException as err:
                print("Error: %s", str(err))
                sys.exit(1)

    def get_time(self, input_time):
        indate = str(input_time).split('.')
        input_date = datetime.datetime.strptime(indate[0], '%Y-%m-%d %H:%M:%S')
        return input_date

    def generate_gerrit_counts(self):
        currdate = datetime.datetime.utcnow()
        rest = self.gerrit_rest
        date_range = (currdate - timedelta(days=self.date_range))
        date_range_str = date_range.strftime("%Y-%m-%d")
        gerrit_changeid_link = 'http://review.couchbase.org/#/c/'

        # Dump the result to email.txt file:
        with open(email_file, 'w') as fl:
            patt80 = "=" * (80)
            patt33 = "=" * (33)
            fl.write(f"\n{patt80}\n")
            fl.write(f"\n{patt33} GERRIT Count {patt33}\n")
            fl.write(f"\n{patt80}\n\n")
            fl.write(f'\nDate Range - {date_range}')
            fl.write(f'\nFrom Date (UTC): {currdate}')
            fl.write(f'\nTo Date (UTC): {date_range}')
            fl.write('\n')
            for u_email in self.gerrit_user_accounts:
                try:
                    query = ["status:merged"]
                    query += ["owner:" + u_email]
                    query += ["after:" + date_range_str]
                    changes = rest.get("/changes/?q=%s" % "%20".join(query))
                except RequestException as err:
                    print("Error: %s", str(err))

                count = 0
                repos = collections.defaultdict(list)
                commit_subjects = list()
                for change in changes:
                    message = gerrit_changeid_link + str(change['_number']) + ' -- ' + change['subject']
                    repos[change['project']].append(message)
                    count = count + 1

                # write/print the result
                fl.write(f'\nUser: {self.gerrit_user_accounts[u_email]}\n')
                fl.write(f'Total Commit(s): {count}\n')
                for repo, mesage in repos.items():
                    fl.write(f'repo: {repo}\n')
                    commit_subjects = sorted(repos[repo], key=len, reverse=True)
                    for msg in commit_subjects:
                        fl.write(msg)
                        fl.write('\n')
                    fl.write('\n')

    def gerrit_commit_caller(self):
        self.generate_gerrit_user_name()
        self.generate_gerrit_counts()


def send_email(smtp_server, recipient, message):
    msg = EmailMessage()
    msg.set_content(message['body'])

    msg['Subject'] = message['subject']
    msg['From'] = 'build-team@couchbase.com'
    msg['To'] = recipient

    try:
        s = smtplib.SMTP(smtp_server)
        s.send_message(msg)
    except smtplib.SMTPException as error:
        print('Mail server failure: %s', error)
    finally:
        s.quit()


def parse_args():
    parser = argparse.ArgumentParser(description="Get private repos")
    parser.add_argument('--conf',
                        help="Project config category for each private repos",
                        default='projects.ini')
    parser.add_argument('-gerritconf', '--gerrit-config',
                        help='Configuration file for Gerrit',
                        default='patch_via_gerrit.ini')
    parser.add_argument('-gitconf', '--git-config',
                        help='Configuration file for Git API',
                        default='git_committer.ini')
    parser.add_argument('-d', '--date-range',
                        help='Date range to query',
                        default='7')
    parser.add_argument('-r', '--recipient',
                        help='Email recipient')
    args = parser.parse_args()
    return args


def main():
    '''
    Create Gerrit commit object and Git object
    Call gerrit_commit_caller and git_commit_caller functionto drive the
    program to generate commit counts
    '''

    # Remove program generated file
    try:
        os.remove(email_file)
    except OSError:
        pass

    gerritObj = GenerateGerritCommits(parse_args())
    gerritObj.gerrit_commit_caller()
    gitObj = GenerateGitCommits(parse_args())
    gitObj.git_commit_caller()

    # Send Email
    date_range = gerritObj.date_range
    smtp_server = gerritObj.smtp_server
    recipient = gerritObj.recipient

    email_message = {}
    with open(email_file) as fl:
        email_message['subject'] = f'Gerrit/Git commit - {date_range} day(s) report'
        email_message['body'] = str(fl.read())

    send_email(smtp_server, recipient, email_message)


if __name__ == '__main__':
    main()
