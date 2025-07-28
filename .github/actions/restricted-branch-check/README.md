# Restricted Branch Check Workflow Components

This directory contains composite actions specifically designed for the Restricted Branch Check workflow.

## Overview

The Restricted Branch Check workflow is split into separate composite actions to improve maintainability, readability, and testability. Each action has a specific responsibility, and they are orchestrated by the main workflow file.

## Components

### 1. 01-validate-inputs

Validates the input parameters (PR number, PR title, base ref) for correctness and security.

- **Inputs**: `pr_number`, `base_ref`, `pr_title`
- **Outputs**: `status`, `error_message`, `error_type`

### 2. 02-validate-organization

Checks if the repository belongs to an allowed organization. The allowed organizations are hardcoded within the action for security.

- **Inputs**: `repository`
- **Outputs**: `status`, `error_message`, `error_type`, `organization`

### 3. 03-setup-environment

Sets up the required environment for the restriction check by checking out repositories and installing tools.

- **Inputs**: `build_tools_repo`, `build_tools_ref`, `manifest_repo`, `manifest_ref`, `jira_url`, `jira_username`, `jira_api_token`
- **Outputs**: `status`, `error_message`, `error_type`, `build_tools_path`, `manifest_path`

### 4. 04-run-restriction-check

Runs the core restriction check logic and processes results based on exit codes.

- **Inputs**: `base_ref`, `repository`, `pr_number`, `pr_title`, `jira_url`, `jira_username`, `jira_api_token`, `build_tools_path`
- **Outputs**: `status` (success, restriction, or error), `error_type`, `error_message`, `restriction_reason`, `restriction_release`, `restriction_approval_ticket`, `restriction_type`, `check_result`, `checked_manifests`, `checked_project`, `checked_branch`

### 5. 05-generate-summary

Generates a GitHub summary based on the results of the restriction check.

- **Inputs**: `status`, `error_message`, `error_type`, and various result details
- **Outputs**: None (writes to GitHub summary)

## Workflow Structure

1. **01-validate-inputs**: Verify PR number and base ref
2. **02-validate-organization**: Check if repository is in allowed organization
3. **03-setup-environment**: Set up tools and repositories
4. **04-run-restriction-check**: Execute the core logic
5. **05-generate-summary**: Create user-friendly output
6. **Set Final Status**: Determine overall workflow status

## Error Handling

Each action uses a consistent error handling approach:

- All actions set `status` to indicate success or failure
- All error conditions set both `error_type` and `error_message`
- Error types are standardized across actions (e.g., `input_validation_error`, `org_not_allowed`, `jira_auth`)
- The main workflow collects and forwards errors to the summary generator

### Error Types

- **input_validation_error**: Invalid input parameters (PR number, base ref, etc.)
- **org_not_allowed**: Repository organization not on the allowlist
- **setup_error**: Environment setup failure (repo checkout, tool installation)
- **jira_auth**: JIRA authentication issues (expired token, invalid credentials)
- **jira_connection**: JIRA connectivity problems (network, URL config)
- **incomplete_check**: Script executed but didn't provide expected outputs
- **general**: General technical errors in the restriction check

## Usage

These composite actions are used by the main workflow file at `.github/workflows/restricted-branch-check.yml`. They are not designed to be used independently.
