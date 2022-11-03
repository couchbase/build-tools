import argparse
import sys
from api import Gerrit, GitHub, logger


def group_members_not_in_org(gerrit_group, github_org):
    return [
        group_member
        for group_member
        in [
            gerrit_user
            for gerrit_user
            in gerrit.group_members(gerrit_group)]
        if not github.user_id_is_in_org(group_member['github_id'],
                                        github_org)]


def org_members_not_in_group(github_org, gerrit_group):
    return [
        gerrit_user
        for gerrit_user
        in gerrit.users()
        if gerrit_user.get('github_id')
        in [github_user['id']
            for github_user
            in github.org_members(github_org)
            if not gerrit.github_user_id_is_in_group(
                github_user['id'],
                gerrit_group)]]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Onboard/Offboard')
    parser.add_argument('--gerrit-group',
                        type=str,
                        help='Gerrit group')
    parser.add_argument('--github-org',
                        type=str,
                        help='GitHub org')
    parser.add_argument('--config',
                        type=str,
                        help='Config file')
    parser.add_argument('--dry-run',
                        action='store_true',
                        help='List changes, but do not make any')

    args = parser.parse_args()
    if not args.config:
        logger.critical("No config file specified")
        parser.print_usage()
        sys.exit(1)

    if not args.github_org:
        logger.critical("No github org specified")
        parser.print_usage()
        sys.exit(1)
    else:
        github_org = args.github_org

    if not args.gerrit_group:
        logger.critical("No gerrit group specified")
        parser.print_usage()
        sys.exit(1)
    else:
        gerrit_group = args.gerrit_group

    gerrit = Gerrit.from_config_file(args.config, args.dry_run)
    github = GitHub.from_config_file(args.config, args.dry_run)

    add_response = ""
    remove_response = ""

    # If users are in `github_org` and non-noop, ensure they're in
    # `gerrit_group`
    add_response = gerrit.add_members_to_group(gerrit_group, [
        member
        for member
        in org_members_not_in_group(github_org, gerrit_group)
        if member['id'] not in gerrit.noop_userids],
        f"absent from gerrit group {gerrit_group}")

    # If users aren't in `github_org`, remove them from all non-noop gerrit
    # groups
    for group in gerrit.groups():
        if group in gerrit.noop_groups:
            logger.info(f"Not removing users from '{group}' (noop group)")
        else:
            remove_response += gerrit.remove_members_from_group(group, [
                member
                for member
                in group_members_not_in_org(group, github_org)
                if member['id'] not in gerrit.noop_userids],
                f"absent from github org {github_org}")

    if add_response:
        logger.info(add_response)
    if remove_response:
        if(add_response):
            print()
        logger.info(remove_response)

    if not any([add_response, remove_response]):
        logger.info("No changes")
