import sys
from api import API, logger
from github import Github, UnknownObjectException


class GitHub(API):
    """
    Class used to interact with the GitHub API.

    Results are cached in underscore-prefixed attributes, as well as
    being returned directly from the methods.
    """
    @classmethod
    def from_config_file(cls, config_path, dry_run):
        config = super(GitHub, cls).from_config_file(config_path, 'github')
        if 'github_token' not in config:
            logger.error(
                "Config missing - ensure github_token is present in [github "
                f"section of {config_path}")
            sys.exit(1)
        return GitHub(config['github_token'], dry_run)

    def __init__(self, token, dry_run):
        """
        Parameters
        ----------
        token : str
            Github access token
        dry_run : bool
            if true, changes are reported but not committed
        """
        self.dry_run = dry_run
        self.g = Github(token)
        self._orgs = {}
        self._org_members = {}

    def org(self, org):
        """
        Retrieve a single org from github

        Parameters
        ----------
        org : string
            the org name
        """
        self._orgs[org] = self.g.get_organization(org)
        return self._orgs[org]

    def org_members(self, org):
        """
        Retrieve all members of a given org

        Parameters
        ----------
        org : string
            the org name
        """
        try:
            if org not in self._org_members:
                members = self.org(org).get_members()
                self._org_members[org] = [{
                    "id": str(member._id.value),
                    "username": member._login.value
                } for member in members]
            return self._org_members[org]
        except UnknownObjectException as e:
            print(f"Github organisation {org} does not exist")
            sys.exit()

    def user_id_is_in_org(self, user_id, org):
        """
        Check if a specified user ID is in an org

        Parameters
        ----------
        user_id : string
            needle
        org : string
            haystack
        """
        if user_id in [member['id'] for member in self.org_members(org)]:
            return True
