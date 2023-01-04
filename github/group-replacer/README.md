# Github group replacer

The purpose of this helper script is to replace an existing 'from' team with
a given 'to' team for all repositories in a specified GitHub organisation.

It requires an access token with repo read/write access, present in the
environment as GITHUB_TOKEN, once present, run with

./app.py --org [org] --from-team-slug=[from] --to-team-slug=[to] [--dry-run]
