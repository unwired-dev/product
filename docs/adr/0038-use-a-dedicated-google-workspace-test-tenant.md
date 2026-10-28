# Use a dedicated Google Workspace test tenant

## Consumer Gmail amendment, 2026-10-29

The owner's decision in [#1527](https://github.com/unwired-dev/product/issues/1527)
supersedes the Workspace, organization-owned domain and internal OAuth requirements
below. Gmail qualification uses dedicated project-controlled consumer accounts
with External OAuth under the [operational runbook](../gmail-provider-test-tenant.md).
That runbook owns provisioning, scope and readiness requirements. Synthetic-only
mail, protected credentials, isolated test resources and real provider/native
evidence remain required. This amendment does not change Microsoft or IMAP/SMTP
certification requirements or qualify Workspace administrator policies.

## Original decision

Gmail compatibility testing uses a dedicated Provider Test Tenant with an internal OAuth application and at least two mail users whose Provider Test Mailboxes contain only Synthetic Test Messages, rather than personal Gmail accounts or an external OAuth application in Testing status. The tenant incurs ongoing cost and administration, but gives scheduled tests stable authorization, controlled identities, realistic Gmail behavior, and a privacy boundary that prevents personal or production mail from entering Provider Test Mailboxes. Provisioning is intentionally deferred until Gmail release compatibility is scheduled; the tenant is not required for local IMAP/SMTP development or approval of the exact-pinned Mail Engine dependency.
