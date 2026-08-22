# Gmail Provider Test Tenant provisioning

Status: awaiting authorized operator attestation.

This runbook is the repository-safe handoff for provisioning the human-owned Google Workspace Provider Test Tenant. It does not prove that the tenant exists or grant automation access. An authorized human operator must complete the external steps and publish the redacted readiness record described below before the tenant is treated as ready.

## Safety boundary

- Use a dedicated, project-controlled Google Workspace tenant containing only Provider Test Mailboxes and Synthetic Test Messages.
- Do not add personal or production identities, aliases, forwarding destinations, personal or production recovery addresses, or mailbox content.
- Keep the tenant domain, user addresses, administrator identities, recovery material, billing details, OAuth credentials, tokens, and mailbox content in the team's approved protected systems. Do not place them in source control, GitHub issues, pull requests, logs, screenshots, or Mail Test Evidence.
- Keep the Provider Test Tenant separate from the Provider Test Project. The tenant owns the synthetic identities; the isolated project owns OAuth clients, Gmail API quotas, Pub/Sub resources, and protected automation credentials.
- Give autonomous agents only redacted readiness and Provider Compatibility Run evidence. Never give them reusable Workspace, Gmail, or Google Cloud credentials.

## Human provisioning procedure

1. Record the accountable administration, security, recovery, lifecycle, and cost-responsibility roles in the team's protected operational documentation.
2. Create a dedicated Google Workspace tenant controlled by the project. Configure organization-controlled recovery and require MFA for every administrator before adding test mailboxes.
3. Create at least two Provider Test Mailboxes. Confirm that every user, alias, recovery route, forwarding rule, and mailbox is isolated from personal and production identities.
4. Configure the OAuth consent audience as internal to this tenant. The Apple client owns consent and scope selection and currently requests only `openid`, `email`, and `https://www.googleapis.com/auth/gmail.modify`; do not approve broader Gmail scopes for this tenant unless the client implementation and this document change together. The protected TypeScript workflow must consume only credentials with this attested scope set and must not broaden Gmail scopes.
5. Store credentials, recovery material, tokens, and any tenant identifiers only in the approved secret and protected-document systems. Record lifecycle procedures for access review, operator replacement, user rotation, billing review, incident response, and tenant retirement.
6. Have an authorized operator verify the protected record and the live tenant configuration. The verifier must confirm the synthetic-only boundary without copying sensitive values into the readiness record.
7. Publish the completed redacted readiness record in a reviewed pull request. Run `pnpm mail:test readiness inspect --json` before review and `pnpm mail:test readiness require-ready --json` after completing the record. Only a record with `status: ready` and every required Boolean set to `true` authorizes subsequent automation work.

## Current redacted readiness record

The canonical readiness artifact is [`gmail-provider-test-tenant-readiness.json`](gmail-provider-test-tenant-readiness.json). An authorized operator updates it in a reviewed pull request after human verification. Keep `schema_version` set to `1`, change `status` from `awaiting_operator_attestation` to `ready`, set every Boolean field to `true`, provide an ISO 8601 UTC `verified_at`, and provide a non-identifying lowercase role slug such as `provider-compatibility-authorizer` in `authorizer_role`. Do not include domains, email addresses, names, client identifiers, project identifiers, secret names, recovery channels, or links to protected systems.

`pnpm mail:test readiness inspect --json` parses the exact documented schema and rejects unknown fields and missing or malformed values while reporting incomplete controls. `pnpm mail:test readiness require-ready --json` additionally exits unsuccessfully unless `status` is `ready`, the timestamp and role are present, and every Boolean is `true`. Protected Provider Compatibility workflows must run the latter command before accessing credentials or provider resources.

## Handoff after readiness

The authorized operator may give the redacted record to the maintainer implementing the protected Gmail workflow. That maintainer must verify the record before configuring automation and must keep all reusable credentials behind the protected workflow described in [ADR 0041](adr/0041-broker-provider-compatibility-through-protected-workflows.md).

This runbook implements the repository-side handoff for [issue #302](https://github.com/unwired-dev/product/issues/302). Actual tenant creation and protected operational attestation remain human actions.
