# Scripts for testing branch restriction

This utility checks if a change affects a restricted branch, and if so, whether the commit has appropriate approval in JIRA.

## How It Works

The restriction checker:
1. **Identifies restricted branches** by scanning manifest files for branches marked as "restricted"
2. **Extracts JIRA tickets** from commit messages (e.g., `CBD-1234`, `MB-5678`)
3. **Verifies approval** by checking if tickets are linked to the release approval ticket
4. **Blocks or allows** the PR based on approval status

This prevents unauthorized changes from being merged into release branches without proper product management approval.

## Local Testing

For local testing, you want to run:

    uv run test-restriction


Run just that command for help. This will do either
restricted-manifest-check (for changes to the `manifest` project) or
restricted-branch-check (for any other changes).

## Usage Environments

### Gerrit

When running in Gerrit, the script uses environment variables set by the Gerrit trigger:
- `GERRIT_PROJECT`
- `GERRIT_BRANCH`
- `GERRIT_CHANGE_COMMIT_MESSAGE`
- `GERRIT_CHANGE_URL`
- `GERRIT_PATCHSET_NUMBER`
- `GERRIT_EVENT_TYPE`

JIRA credentials are read from `~/.ssh/cloud-jira-creds.json`.

### GitHub Actions

When running in GitHub Actions, the script uses these environment variables:

**Automatically set by GitHub/workflow:**
- `GITHUB_BASE_REF` - The target branch of the PR
- `GITHUB_REPOSITORY` - The repository name (e.g. "owner/repo")
- `GITHUB_TOKEN` - GitHub token with read access to repository
- `PR_NUMBER` - The PR number to check
- `PR_TITLE` - The PR title (used for JIRA ticket extraction)

**Must be configured as secrets:**
- `JIRA_URL` - URL of the JIRA instance
- `JIRA_USERNAME` - JIRA username
- `JIRA_API_TOKEN` - JIRA API token

## Exit Codes

The script uses different exit codes to communicate status to the calling workflow:
- `0` - Check passed, no restrictions apply
- `5` - Legitimate branch restriction applies (PR blocked)
- `6` - Technical error occurred (e.g., JIRA authentication, network issues)

The script also writes detailed error information to `$GITHUB_OUTPUT` for consumption by the workflow.

## Error Handling

The script provides detailed error information for various failure scenarios:

- **JIRA Authentication Issues**: Detailed errors for expired tokens, invalid credentials, etc.
- **JIRA Connection Issues**: Problems with JIRA URL, network connectivity, etc.
- **Missing Tickets**: When PR title doesn't reference any JIRA tickets
- **Unapproved Tickets**: When tickets aren't linked to the appropriate release approval ticket

## Setting Up the Workflow

To enable restriction checking on a repository:

1. **Configure JIRA secrets** at the repository or organization level:
   - `JIRA_URL` - Your JIRA instance URL
   - `JIRA_USERNAME` - Service account username
   - `JIRA_API_TOKEN` - API token for the service account

2. **Add the workflow file** `.github/workflows/restricted-branch-check.yml`:

```
name: Restricted Branch Check

on:
  pull_request_target:
    types: [opened, reopened, synchronize]

jobs:
  run-check:
    uses: couchbase/build-tools/.github/workflows/restricted-branch-check.yml@master
    with:
      pr_number: ${{ github.event.pull_request.number }}
      pr_title: ${{ github.event.pull_request.title }}
    secrets:
      JIRA_URL: ${{ secrets.JIRA_URL }}
      JIRA_USERNAME: ${{ secrets.JIRA_USERNAME }}
      JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
```

## Repository Organization Allowlist

For security, this workflow contains a hardcoded allowlist of approved organizations:
- `couchbase` - Main Couchbase repositories
- `couchbasedeps` - Couchbase dependency repositories
- `couchbaselabs` - Couchbase Labs experimental repositories

The organization allowlist is not configurable by workflow consumers to prevent security bypass.

The workflow protects the **target repository** (where the PR is going) and allows contributions from **any fork**. For example:
- ✅ Fork `alice/server` → Target `couchbase/server` (allowed - target is in allowlist)
- ❌ Fork `alice/server` → Target `randomorg/server` (blocked - target not in allowlist)

## Branch Protection Setup

You must also enable branch protection rules to prevent PRs from being merged if the branch is restricted:

1. Go to repository Settings → Branches
2. Add a branch protection rule for restricted branches
3. Enable "Require status checks to pass before merging"
4. Add "Check Branch Restrictions" to required status checks
5. Ensure "Enforcement Status" is active
