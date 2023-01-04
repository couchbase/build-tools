#!/usr/bin/env python3

"""This script is used to switch out one team for another across all the
repositories in a given Github organisation.

Note: Only the source team's permissions are migrated (members are not added
or removed) and the destination team must already exist
"""

import argparse
import sys
from github import Github
from os import environ


class GitHubTeamMover():
    def __init__(self, org, dry_run):
        self.connect()
        self.get_org(org)
        self.dry_run = dry_run

    def connect(self):
        try:
            self.g = Github(environ["GITHUB_TOKEN"])
        except KeyError:
            print("ERROR: Ensure GITHUB_TOKEN is present in environment")
            exit(1)

    def get_org(self, org):
        self.org = self.g.get_organization(org)

    def get_repos_team_present_in(self, team_slug):
        repos = []
        for repo in self.org.get_repos():
            if(team_slug in [t.slug for t in repo.get_teams()]):
                repos.append(repo)
        return repos

    def remove_from_repo(self, team_slug, repo):
        team = self.org.get_team_by_slug(team_slug)
        print("Removing", team.slug, "from", repo.name, "...", end=" ")
        if not self.dry_run:
            team.remove_from_repos(repo)
            print("ok!")
        else:
            print("no action (dry run)")

    def add_to_repo(self, team_slug, repo, role):
        team = self.org.get_team_by_slug(team_slug)
        print("Adding", team.slug, "to", repo.name,
              f"({role} access) ...", end=" ")
        if not self.dry_run:
            team.add_to_repos(repo)
            self.set_repo_role(team, repo, role)
            print("ok!")
        else:
            print("no action (dry run)")

    def get_repo_role(self, team_slug, repo):
        team = self.org.get_team_by_slug(team_slug)
        permission = team.get_repo_permission(repo)
        if permission.admin:
            role = "admin"
        elif permission.maintain:
            role = "maintain"
        elif permission.push:
            role = "push"  # this is called 'write' in UI
        elif permission.triage:
            role = "triage"
        elif permission.pull:
            role = "read"
        else:
            print(
                f"Couldn't determine permission for {team_slug} on ",
                repo.full_name)
            sys.exit(1)
        return role

    def set_repo_role(self, team, repo, role):
        return team.update_team_repository(repo, role)

    def switch_teams(self, from_team, to_team):
        repos_present_in = self.get_repos_team_present_in(from_team)
        for repo in repos_present_in:
            role = self.get_repo_role(from_team, repo.full_name)
            self.add_to_repo(to_team, repo, role)
            self.remove_from_repo(from_team, repo)


parser = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
parser.add_argument('--org', action='store', required=True)
parser.add_argument('--from-team-slug', action='store', required=True)
parser.add_argument('--to-team-slug', action='store', required=True)
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()


team = GitHubTeamMover(args.org, args.dry_run)
team.switch_teams(args.from_team_slug, args.to_team_slug)
