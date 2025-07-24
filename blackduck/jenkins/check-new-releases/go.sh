#!/bin/bash -e

uv run check_new_releases.py

if [ ! -z "$(git status --porcelain)" ] && [ "$1" == "--push" ]; then
  git remote add gerrit ssh://${GERRIT_USER}@review.couchbase.org:29418/build-tools
  git commit -am "Blackduck: add missing versions"
  git push gerrit HEAD:refs/for/master
fi
