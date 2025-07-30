#!/bin/bash -e

uv run check_new_releases.py

if [ ! -z "$(git status --porcelain)" ]; then
  if [ "$1" == "--push" ]; then
    git remote add gerrit ssh://${GERRIT_USER}@review.couchbase.org:29418/build-tools
    git commit -am "Blackduck: add missing versions"
    git push gerrit HEAD:refs/for/master
    echo "Changes have been pushed to Gerrit. Please review the changes at https://review.couchbase.org"
    exit 1
  else
    echo "Changes detected but not pushing. Run with --push to submit to Gerrit."
  fi
else
  echo "No changes detected."
fi
