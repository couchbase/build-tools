import json
import os
import re
import requests
import sys
import shutil
import subprocess
import tempfile
from api import API, logger


class REST():
    def __init__(self, url, username, token):
        self.url = url
        self.username = username
        self.token = token

    def decode(self, text):
        return text[5:]

    def get(self, path):
        """
        Retrieve output from a GET to `path`

        Parameters
        ----------
        path : str
            the path being queried on the server
        """
        res = requests.get(f'{self.url}{path}',
                           auth=(self.username, self.token))
        if res.status_code == 401:
            logger.critical(
                "Got status 401 from gerrit host, check credentials")
            sys.exit(1)
        if len(res.text) > 5:
            res.json = json.loads(self.decode(res.text))
        return res

    def post(self, path, payload):
        """
        Retrieve output from a POST to `path`

        Parameters
        ----------
        path : str
            the path being called on the server
        payload : object
            the payload
        """
        res = requests.post(f'{self.url}{path}', json=payload,
                            auth=(self.username, self.token))
        if res.status_code == 401:
            logger.critical(
                "Got status 401 from gerrit host, check credentials")
            sys.exit(1)
        if len(res.text) > 5:
            res.json = json.loads(self.decode(res.text))
        return res


class Gerrit(API):
    """
    Class used to interact with the gerrit API.

    Where results are retrieved, these are cached in underscore-prefixed
    attributes, as well as being returned directly from the methods.

    Attributes
    ----------
    url : str
        url of the Gerrit server.
    username : str
        Gerrit user
    token : str
        HTTP password for the gerrit user.
    _groups : dict
        list of groups available once queried.
    _group_members : dict
        members of each queried group.
    _users : dict
        all users.
    """
    @classmethod
    def from_config_file(cls, config_path, dry_run):
        """
        Factory method to instantiate a Gerrit object given a config
        file)

        Parameters
        ----------
        config_path : str
            the config file containing connection information
        """
        config = super(Gerrit, cls).from_config_file(config_path, 'gerrit')
        missing_config_items = list(set([
            'hostname',
            'web_protocol',
            'web_port',
            'ssh_port',
            'username',
            'gerrit_token',
            'noop_groups',
            'noop_userids'] - config.keys()))
        if len(missing_config_items) > 0:
            logger.error(
                f"Config missing - ensure {', '.join(missing_config_items)} "
                f"present in [gerrit] section of {config_path}")
            sys.exit(1)
        return Gerrit(
            config['hostname'],
            config['web_protocol'],
            config['web_port'],
            config['ssh_port'],
            config['username'],
            config['gerrit_token'],
            config['noop_groups'].split(","),
            config['noop_userids'].split(","),
            dry_run
        )

    def __init__(self, hostname, web_protocol, web_port, ssh_port, username, token, noop_groups, noop_userids, dry_run):
        """
        Parameters
        ----------
        dry_run : bool
            whether any modifications will be made
        hostname: str
            Gerrit server hostname
        web_protocol : str
            protocol used by gerrit web frontend (http/https)
        web_port : str
            port number used by web service
        ssh_port : str
            port numberused by ssh service
        username : str
            Gerrit username
        token : str
            Gerrit HTTP access token
        noop_groups: list(str)
            Groups which should not be modified
        noop_userids: list(str)
            Users which should not be modified
        """
        self.dry_run = dry_run
        self.hostname = hostname
        self.web_protocol = web_protocol
        self.web_port = web_port
        self.ssh_port = ssh_port
        self.username = username
        self.token = token
        self.noop_groups = noop_groups
        self.noop_userids = noop_userids
        self._groups = {}
        self._group_members = {}
        self._users = {}
        self.map = {}
        self.path = tempfile.mkdtemp()
        logger.debug(f"Created temp dir {self.path}")
        self.init()
        self.fetch(
            f"ssh://{self.username}@{hostname}:{self.ssh_port}/All-Users",
            "refs/meta/external-ids")
        self.checkout("FETCH_HEAD")
        self.map_ids()
        self.rest = REST(
            f"{web_protocol}://{hostname}:{web_port}", username, token)

    def __del__(self):
        """
        Remove temp dir on completion
        """
        shutil.rmtree(self.path)
        logger.debug(f"Removed temp dir {self.path}")

    def init(self):
        """
        Initialise a git repo
        """
        os.chdir(self.path)
        call = subprocess.run(
            ["git", "init"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if call.returncode != 0:
            logger.critical(
                f"Couldn't initialise git repo - {call.stderr.decode()}")
            sys.exit(1)
        else:
            logger.debug("Git repo initialised")

    def map_ids(self):
        """
        Populate self.map with a mapping of [gerrit] user ids and [github]
        oauth ids
        """
        re_oauth_id = re.compile(r"\[externalId \"github-oauth:([0-9]+)\"\]")
        re_account_id = re.compile("accountId = ([0-9]+)")
        for root, dirs, files in os.walk(self.path):
            if ".git" in dirs:
                dirs.remove(".git")
            for file in files:
                oauth_id = account_id = None
                filename = os.sep.join([root, file])
                with open(filename) as f:
                    content = f.read()
                    oauth_id = re_oauth_id.search(content)
                    account_id = re_account_id.search(content)
                    if(oauth_id and account_id):
                        oauth_id = str(oauth_id.group(1))
                        account_id = str(account_id.group(1))
                        self.map[account_id] = oauth_id

    def oauth_id(self, gerrit_user_id):
        """
        Retrieve a single oauth id from a given gerrit user id

        Parameters
        ----------
        gerrit_user_id : string
            the needle
        """
        return self.map.get(str(gerrit_user_id), None)

    def checkout(self, ref):
        """
        Check out a specific ref of the git repo at `self.path`

        Parameters
        ----------
        ref : string
            the ref to checkout
        """
        os.chdir(self.path)
        call = subprocess.run(["git", "checkout", ref],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if call.returncode != 0:
            logger.critical(
                f"Couldn't checkout {ref} - {call.stderr.decode()}")
            sys.exit(1)
        else:
            logger.debug(f"Checked out {ref}")

    def init(self):
        """
        Initialise a git repo
        """
        os.chdir(self.path)
        call = subprocess.run(
            ["git", "init"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if call.returncode != 0:
            logger.critical(
                f"Couldn't initialise git repo - {call.stderr.decode()}")
            sys.exit(1)
        else:
            logger.debug("Git repo initialised")

    def fetch(self, repo, ref):
        """
        Fetch a repo

        Parameters
        ----------
        repo : string
            the repo to fetch
        ref : string
            the ref to fetch
        """
        os.chdir(self.path)
        call = subprocess.run(["git", "fetch", repo, ref],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if call.returncode != 0:
            logger.critical(
                f"Couldn't fetch {ref} from {repo} - {call.stderr.decode()}")
            sys.exit(1)
        else:
            logger.debug(f"{repo} {ref} fetched")

    def _get_users(self, active=True, offset=0):
        """
        Retrieve list of all active or inactive users, starting at `offset`

        Parameters
        ----------
        active : bool
            whether to retrieve active or inactive users
        offset : int, optional
            the offset from which users are retrieved
        """
        logger.debug(f"Retrieving active={active} accounts, offset={offset}")
        state = 'active' if active else 'inactive'
        users = self.rest.get(
            f"/a/accounts/?q=is:{state}&o=DETAILS&start={offset}").json
        if('_more_accounts' in users[len(users)-1]
           and users[len(users)-1]['_more_accounts'] is True):
            del users[len(users)-1]['_more_accounts']
            users += self._get_users(active=active, offset=offset+len(users))
        return users

    def users(self):
        """
        Retrieve a list of all active users
        """
        if not self._users:
            users = self._get_users(active=True)
            self._users = [{
                "id": str(user['_account_id']),
                "github_id": str(self.oauth_id(user['_account_id'])),
                "username": user.get('username', ''),
                "name": user.get('name', ''),
                "email": user.get('email', '')} for user in users]
        return self._users

    def groups(self):
        """
        Retrieve a list of all groups
        """
        if not self._groups:
            self._groups = self.rest.get('/a/groups/').json
        return self._groups

    def group(self, group_name):
        """
        Retrieve information on single group `group_name`

        Parameters
        ----------
        group_name : str
            the name of the group being retrieved
        """
        if group_name not in self.groups():
            logger.critical(f'Group does not exist: {group_name}')
            sys.exit(1)
        else:
            return self._groups[group_name]

    def add_members_to_group(self, group, members, reason):
        """
        Add members to a group

        Parameters
        ----------
        group : str
            the name of the group the users will be added to
        members : list
            a list of users who should be added
        reason : str
            a short explanation of why the users are being added
        """
        actions = ""
        if len(members) > 0:
            member_ids = [member['id'] for member in members]
            if not self.dry_run:
                actions = "Added"
                res = self.rest.post(
                    f"/a/groups/{group}/members.add", {"members": member_ids})
                success = res.status_code == 200
            else:
                actions = "[Dry run] Would have added"
                success = True
            if success:
                actions = actions + \
                    f" gerrit users to group '{group}' - {reason}"
                actions = actions + "\n    " + \
                    "\n    ".join([member['name'] for member in members])
            else:
                logger.critical(
                    f"Failed to add users {member_ids} to gerrit group "
                    f"{group}")
            actions = actions + "\n"
        return actions

    def remove_members_from_group(self, group, members, reason):
        """
        Remove members from a group

        Parameters
        ----------
        group : str
            the name of the group the users will be removed from
        members : list
            a list of users who should be removed
        reason : str
            a short explanation of why the users are being removed
        """
        actions = ""
        if len(members) > 0:
            member_ids = [member['id'] for member in members]
            if not self.dry_run:
                actions = "Removed"
                res = self.rest.post(
                    f"/a/groups/{group}/members.delete",
                    {"members": member_ids})
                success = res.status_code == 204
            else:
                actions = "[Dry run] Would have removed"
                success = True
            if success:
                actions = actions + f" users from group '{group}' - {reason}"
                actions = actions + "\n    " + \
                    "\n    ".join([member['name'] for member in members])
            else:
                logger.critical(
                    f"Failed to remove users {member_ids} from gerrit group "
                    f"{group} - status: {res.status_code}")
                sys.exit(1)
            actions = actions + "\n"
        return actions

    def group_members(self, group_name):
        """
        Retrieve member list for `group_name`

        Parameters
        ----------
        group_name : str
            the name of the group being queried
        """
        if group_name not in self._group_members:
            members = self.rest.get(
                f'/a/groups/{self.group(group_name)["group_id"]}/members').json
            self._group_members[group_name] = [{
                "id": str(member['_account_id']),
                "name": member.get('name', ''),
                "username": member.get('username'),
                "github_id": str(self.oauth_id(member['_account_id'])),
                "github_username":
                    str(self.oauth_id(member['_account_id'])),
                "email": member['email'] if 'email' in member else ''
            } for member in members]
        return self._group_members[group_name]

    def github_user_id_is_in_group(self, user_id, group):
        """
        Check whether a given user is a member of a group

        Parameters
        ----------
        user_id : str
            the user id of the github user
        group : str
            the gerrit group being searched
        """
        if user_id in [
                member['github_id']
                for member
                in self.group_members(group)]:
            return True
