# Blackduck constants
SEVERITY_LIST = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']
EXCLUDED_PROJECTS = [
    'couchbase-data-api',
    'couchbase-lite-core',
    'couchbase-service-broker',
    'ceej-test',
    'conda',
    'cbconda',
    'direct-nebula',
    'couchbase-stellar-gateway',
    'couchbase-goldfish-nebula',
    'python_tools::cb-non-package-installer',
    'blair-dryrun',
    'cbdeps::libsodium',
    'chris-test',
    'terraform-provider-couchbase-capella',
    'vault-plugin-database-couchbasecapella',
    'capella-analytics']

# Jira constants
JIRA_PROJECT_KEY = 'VULN'
JIRA_ISSUE_TYPE = 'Bug'
WORKFLOW_TO_DO_ID = '231'  # Corresponding workflow transition ID in jira
WORKFLOW_DONE_ID = '241'  # Corresponding workflow transition ID in jira
BD_COMPONENT_FIELD = 'customfield_11332'
BD_COMPONENT_VERSION_FIELD = 'customfield_11333'
BD_CVES_FIELD = 'customfield_11270'
BD_DETAIL_FIELD = 'customfield_11271'
BD_LAST_UPDATE_FIELD = 'customfield_11272'
BD_PROJECT_FIELD = 'customfield_11330'
BD_PROJ_VERSION_FIELD = 'customfield_11331'
BD_SEVERITY_FIELD = 'customfield_11329'
DONE_STATUSES = {
    'Not Applicable',
    'Component Not Applicable',
    'Fixed In Later Version',
    'Mitigated',
    'Done'
}
DO_NOT_REOPEN_STATUSES = {
    'To Do',
    'Component Not Applicable',
    'Fixed In Later Version'
}
