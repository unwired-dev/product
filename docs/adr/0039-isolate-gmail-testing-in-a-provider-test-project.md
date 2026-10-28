# Isolate Gmail testing in a Provider Test Project

The [2026-10-29 amendment to ADR 0038](0038-use-a-dedicated-google-workspace-test-tenant.md#consumer-gmail-amendment-2026-10-29)
replaces tenant provisioning below with dedicated test-account provisioning.
The isolated Provider Test Project and its production boundaries remain required.

Gmail compatibility testing uses a dedicated Provider Test Project with its own OAuth client, Gmail API quotas, Pub/Sub resources, and protected credentials, separate from every production Google Cloud project. Provider Compatibility Runs cannot enter production push routes or consume production quotas. Autonomous agents request a Provider Compatibility Run through the protected workflow and receive only redacted Mail Test Evidence rather than reusable Google credentials. This duplicates some provider configuration in exchange for bounded failures, safer automation, and auditable secret access. Project creation is deferred with Provider Test Tenant provisioning until Gmail release compatibility is scheduled; it is not a prerequisite for local mail development or SwiftMail integration.
