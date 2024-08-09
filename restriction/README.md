# Scripts for testing branch restriction

For local testing, you want to run

    rye run test-restriction

Run just that command for help. This will do either
restricted-manifest-check (for changes to the `manifest` project) or
restricted-branch-check (for any other changes).
