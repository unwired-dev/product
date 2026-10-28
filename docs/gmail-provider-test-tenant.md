# Dedicated Gmail test accounts

Status: awaiting [operator attestation](https://github.com/unwired-dev/product/issues/1528)
for the consumer-account setup.

Use at least two dedicated ordinary `@gmail.com` accounts for protected Gmail
qualification. The owner selected this setup on 2026-10-29 in
[#1527](https://github.com/unwired-dev/product/issues/1527); a Google Workspace
subscription or organization-owned domain is not required. This policy change
does not provision accounts or grant automation access.

## Safety boundary

- Use project-controlled **Provider Test Accounts** containing only **Provider
  Test Mailboxes** and **Synthetic Test Messages**.
- Keep personal and production identities, aliases, forwarding destinations,
  recovery routes and mailbox content out of these accounts.
- Keep account addresses, passwords, MFA and recovery material, OAuth credentials,
  tokens and mailbox content in approved protected systems. Do not put them in
  source control, GitHub, logs, screenshots or **Mail Test Evidence**.
- Keep the accounts separate from the isolated **Provider Test Project**, which
  owns test OAuth clients, Gmail API quotas, Pub/Sub routes and protected
  automation credentials. Reuse an existing isolated test project where suitable.
- Give autonomous agents only redacted readiness and **Provider Compatibility
  Run** evidence. Reusable Gmail and Google Cloud credentials stay behind the
  protected operator-run workflow.

## Human provisioning procedure

1. Record the accountable account owner, recovery, security and lifecycle roles,
   plus responsibility for any Google Cloud project costs, in protected records.
2. Create or designate at least two ordinary Gmail accounts reserved for testing.
   Enable MFA on each and use project-controlled recovery. Confirm that every
   mailbox, alias, forwarding rule and recovery route is isolated from personal
   and production use.
3. Configure the test project's OAuth audience as **External**. Use the maintained
   Expo and Mac clients and the four scopes in the
   [authorization inventory](google-registration.md#what-the-hosts-request):
   `openid`, `https://www.googleapis.com/auth/userinfo.email`,
   `https://www.googleapis.com/auth/userinfo.profile` and
   `https://www.googleapis.com/auth/gmail.modify`. Do not broaden Gmail scopes.
4. If the project is in **Testing**, list the designated accounts as test users.
   Gmail grants in this mode expire after seven days; schedule reauthorization
   accordingly. A verified **In production** External project can also authorize
   these accounts. Follow [Google's audience rules](https://support.google.com/cloud/answer/15549945).
   The completed production authorization in #668 does not attest a different
   test project's configuration.
5. Store credentials and recovery material only in approved protected systems.
   Record access review, operator replacement, account rotation and retirement.
6. Have an authorized operator verify the accounts, current clients/scopes and
   the protected native execution path, including the configured test backend
   and Pub/Sub/APNs resources needed by the selected scenarios. Follow
   [protected real OAuth qualification](google-registration.md#protected-real-oauth-qualification).
7. Publish the redacted readiness record below after verification. Only a
   `ready` record meeting the complete schema authorizes protected automation.

Consumer accounts qualify consumer Gmail behavior. Workspace administrator-policy
coverage requires separate Workspace accounts when that coverage is requested.
Scenarios requiring a Google identity without Gmail still need a dedicated
non-Gmail Google identity; an ordinary Google account can provide that case.

## Current redacted readiness record

The earlier schema-1 Workspace attestation from 2026-10-23 covered the retired
Swift client. It does not establish readiness of consumer accounts or the
maintained clients. Schema 2 replaces `tenant` with `accounts`, and
`audience_internal` with `audience_external`; old records must not authorize this
setup. Account provisioning and protected execution have not been newly attested.

The canonical artifact remains the single YAML block in this section of
`docs/gmail-provider-test-tenant.md`. After human verification, an authorized
operator updates it in a reviewed pull request: set `status: ready`, every Boolean
to `true`, `verified_at` to an ISO 8601 UTC timestamp and `authorizer_role` to a
non-identifying role. Do not include addresses, names, client/project identifiers,
secret names, recovery channels or links to protected systems.

```yaml
schema_version: 2
status: awaiting_operator_attestation
verified_at: null
accounts:
  project_controlled: false
  synthetic_only: false
  at_least_two_test_users: false
oauth:
  audience_external: false
  scopes_match_client: false
operations:
  administrative_owner_recorded: false
  mfa_recorded: false
  recovery_recorded: false
  lifecycle_recorded: false
  cost_owner_recorded: false
secrets:
  approved_system_only: false
  repository_exposure_reviewed: false
automation:
  authorizer_role: null
```

The protected workflow must find exactly one artifact, parse schema 2, and reject
unknown fields and missing, duplicate or malformed artifacts. Readiness requires
`status: ready`, a valid UTC `verified_at`, a non-identifying `authorizer_role`
and every Boolean set to `true`. Null metadata is allowed only while awaiting
attestation. All other records fail closed and leave Provider Compatibility Runs
unauthorized.

## Handoff after readiness

The authorized operator supplies only the redacted record to the maintainer of
the protected Gmail workflow. Verify that record before configuring automation;
keep reusable credentials behind the protected workflow described in
[ADR 0041](adr/0041-broker-provider-compatibility-through-protected-workflows.md).
Provisioning and attestation remain operator actions. The completed production
Google authorization in [#668](https://github.com/unwired-dev/product/issues/668)
is unchanged by this test-account policy.
