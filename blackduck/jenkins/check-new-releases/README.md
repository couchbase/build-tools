This script is used to ensure we capture new versions of the various products which use get_source.sh + scan-config.json.

It will step through each of the directories containing these files, cloning the first github repo found in get_source.sh (these can be added in a comment if required) identify the timestamp of the most current tag from the scan-config.json and walks through all the tags from the github repository in chronological order, taking the following action:

- if the tag is older than the most current tag in scan-config.json, skip it
- if the tag is newer than the most current tag in scan-config.json:
  - remove any existing versions from scan-config.json with the same major.minor that are as long or 1 char shorter (to account for suffixes)
  - add the new version to scan-config.json with an interval of 1440

Changes to scan-config.json are staged as the script progresses, then committed and proposed at the end of go.sh
