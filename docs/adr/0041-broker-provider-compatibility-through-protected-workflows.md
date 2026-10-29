# Broker provider compatibility through protected workflows

Autonomous agents request Provider Compatibility Runs through a protected, serialized GitHub Actions workflow and receive only redacted Mail Test Evidence. Environment-scoped secrets remain inside that workflow, which owns scenario execution and cleanup and permits only one run against the shared Provider Test Accounts at a time; agents never receive reusable Gmail, Workspace, Google Cloud, or Convex credentials. This accepts less convenient local debugging to reduce credential exposure and eliminate concurrent mutation of shared provider mailboxes.

Gmail account provisioning and readiness follow the
[operational runbook](../gmail-provider-test-tenant.md), as amended by the owner
on 2026-10-29 in [ADR 0038](0038-use-a-dedicated-google-workspace-test-tenant.md#consumer-gmail-amendment-2026-10-29).
