# Gmail Provider Test Project provisioning

Status: awaiting authorized operator attestation.

This runbook is the repository-safe handoff for provisioning the human-owned Google Cloud Provider Test Project, isolated Convex deployment, and protected GitHub environment used by Gmail Provider Compatibility Runs. It defines the controls and redacted readiness contract; it does not prove that the external resources exist or make their credentials available to agents. An authorized operator must complete the external steps and publish the attestation below before the project is treated as ready.

## Safety boundary

- Use a dedicated non-production Google Cloud project. Do not reuse a production project, billing identity, OAuth client, quota pool, Pub/Sub topic or subscription, service account, IAM binding, credential, or push route.
- Connect only the synthetic identities from the [Provider Test Tenant](gmail-provider-test-tenant.md). Do not add personal or production users, test with copied production mail, or authorize a production mailbox.
- Route the project only to a dedicated non-production Convex deployment and non-production notification configuration. The test deployment must contain no production data, device registrations, routes, keys, or credentials and must never target production devices.
- Grant resource-scoped predefined roles instead of project-wide Owner, Editor, or Viewer roles. Gmail's publisher identity receives Pub/Sub Publisher only on the dedicated topic.
- Keep reusable credentials and protected infrastructure identifiers in the approved secret or operational-document systems. Do not place values, resource identifiers, mailbox addresses, project identifiers, endpoint tokens, screenshots, or protected-console links in source control, issues, pull requests, logs, or Mail Test Evidence.
- Give autonomous agents only the redacted readiness record and redacted Provider Compatibility Run evidence. Agents must not receive Google Cloud, Gmail, Convex, APNs, or test-mailbox credentials.

## Human provisioning procedure

1. Record accountable cloud administration, security, billing, GitHub-environment approval, secret ownership, incident-response, and retirement roles in protected operational documentation.
2. Create a dedicated non-production Google Cloud project with separate billing and bounded Gmail API and Pub/Sub quotas. Enable only the Gmail API, Pub/Sub API, and IAM capabilities required for the compatibility lane.
3. Configure an internal OAuth consent application for the Provider Test Tenant and a dedicated iOS OAuth client for the test app identity. Approve only `openid`, `email`, and `https://www.googleapis.com/auth/gmail.modify`, matching the client. Do not create or distribute an application client secret.
4. Create one dedicated Pub/Sub topic in the same project as the OAuth client. Grant `gmail-api-push@system.gserviceaccount.com` Pub/Sub Publisher on that topic only; do not grant a primitive project role.
5. Create one push subscription to the isolated Convex deployment's `/gmail/push` endpoint with a unique high-entropy verification token. Configure explicit retention, retry, quota, and cleanup bounds. Verify that the subscription, dead-letter configuration if any, and every IAM binding remain inside the Provider Test Project and cannot reach a production endpoint.
6. Create a separate Convex test deployment with no production data or device registrations. Configure the Gmail OAuth audience, Pub/Sub verification token, routing and identity-binding keys, and non-production APNs values under the existing runtime variable names documented below. Verify that its Gmail route cannot resolve a production Product Account, Mailbox Connection, APNs topic, or device.
7. Create the GitHub environment `gmail-provider-compatibility`. Require an authorized human reviewer, prevent self-review, restrict deployment branches to the default branch, and store credentials only as environment secrets. The future protected workflow from issue #304 must name this environment, use a read-only `GITHUB_TOKEN` unless an individual step proves a narrower write need, serialize runs, and expose secrets only to the approved job after authorization.
8. Record the secret inventory, owner role, rotation trigger, rotation procedure, and retirement procedure in protected operational documentation. Verify repository, Actions, Convex, Google Cloud, and test-device logs contain no secret values or protected identifiers.
9. Run an authorized readiness check: complete OAuth consent with a synthetic mailbox, register a Gmail watch on the dedicated topic, deliver a synthetic change through the dedicated subscription and isolated Convex route, capture only content-free evidence, and confirm a production project, endpoint, data set, APNs topic, and device cannot be selected.
10. Have a second authorized operator compare the protected evidence with the live cloud, Convex, GitHub, and notification configuration. Publish only the completed redacted readiness record below.

Google requires Gmail push topics to live in the OAuth client's project and requires `gmail-api-push@system.gserviceaccount.com` to have publish permission on the topic. See [Configure push notifications in Gmail API](https://developers.google.com/workspace/gmail/api/guides/push). GitHub environment secrets remain unavailable until configured protection rules pass; see [Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

## Configuration inventory

The names below are identifiers, not values. Values stay in the named protected system and must never appear in the readiness record.

### GitHub environment `gmail-provider-compatibility`

| Name | Kind | Purpose | Owner and rotation trigger |
| --- | --- | --- | --- |
| `CONVEX_DEPLOY_KEY` | Secret | Authorizes only the isolated Convex test deployment | Backend operator; rotate on access change, suspected exposure, or deployment replacement |
| `GMAIL_PROVIDER_TEST_PRIMARY_ADDRESS` | Secret | Selects the primary synthetic mailbox | Tenant operator; rotate when the mailbox is replaced |
| `GMAIL_PROVIDER_TEST_PRIMARY_REFRESH_TOKEN` | Secret | Restores the primary synthetic Gmail authorization | Tenant operator; rotate on grant change, access change, revocation, or suspected exposure |
| `GMAIL_PROVIDER_TEST_SECONDARY_ADDRESS` | Secret | Selects the independent secondary synthetic mailbox | Tenant operator; rotate when the mailbox is replaced |
| `GMAIL_PROVIDER_TEST_SECONDARY_REFRESH_TOKEN` | Secret | Restores the secondary synthetic Gmail authorization | Tenant operator; rotate on grant change, access change, revocation, or suspected exposure |
| `GMAIL_OAUTH_CLIENT_ID` | Variable | Fixes the dedicated iOS OAuth audience | Cloud operator; update only when the test OAuth client is replaced |
| `GMAIL_PUBSUB_TOPIC` | Variable | Names the dedicated topic used by Gmail watch | Cloud operator; update only when the test topic is replaced |
| `CONVEX_SITE_URL` | Variable | Names the isolated Convex HTTP origin | Backend operator; update only when the test deployment is replaced |

### Isolated Convex deployment

| Name | Kind | Purpose | Owner and rotation trigger |
| --- | --- | --- | --- |
| `GMAIL_OAUTH_CLIENT_ID` | Variable | Validates Google identity proofs against the test OAuth audience | Cloud and backend operators; update with OAuth client replacement |
| `GMAIL_PUSH_VERIFICATION_TOKEN` | Secret | Authenticates the dedicated Pub/Sub push endpoint | Cloud and backend operators; rotate together on access change or suspected exposure |
| `GMAIL_ROUTING_KEY` | Secret | Derives test-only opaque Gmail route identifiers | Backend operator; rotate with the documented previous-key transition |
| `GMAIL_ROUTING_KEY_VERSION` | Variable | Identifies the active routing-key revision | Backend operator; increment with every routing-key rotation |
| `GMAIL_ROUTING_PREVIOUS_KEY` | Transitional secret | Keeps existing test routes reachable during rotation | Backend operator; remove after every active test route renews |
| `GMAIL_ROUTING_PREVIOUS_KEY_VERSION` | Transitional variable | Identifies the transitional routing key | Backend operator; remove with the transitional key |
| `GMAIL_IDENTITY_BINDING_KEY` | Secret | Derives test-only mailbox identity bindings | Backend operator; rotate only with an explicit route invalidation and reauthorization plan |
| `APNS_KEY_ID` | Secret | Selects the non-production APNs signing key | Apple infrastructure operator; rotate with key replacement or suspected exposure |
| `APNS_TEAM_ID` | Secret | Scopes the non-production APNs signing identity | Apple infrastructure operator; update only with account migration |
| `APNS_PRIVATE_KEY` | Secret | Signs notifications for the non-production app identity | Apple infrastructure operator; rotate on access change, key replacement, or suspected exposure |
| `APNS_TOPIC` | Variable | Restricts delivery to the non-production app identity | Apple infrastructure operator; update only with test app-identity replacement |

Quota owners review Gmail and Pub/Sub usage before every compatibility campaign and after anomalous usage. Operators remove expired watches, subscriptions, topics, OAuth grants, service-account bindings, GitHub secrets, Convex data and variables, notification registrations, and the project itself when the lane is retired. Cleanup must fail closed on uncertain ownership.

## Current redacted readiness record

The canonical readiness artifact is the single YAML block in this section of `docs/gmail-provider-test-project.md`. An authorized operator updates it in a reviewed pull request after verifying protected evidence. Keep `schema_version` set to `1`, change `status` from `awaiting_operator_attestation` to `ready`, set every required Boolean to `true`, provide an ISO 8601 UTC `verified_at`, and provide a non-identifying `authorizer_role`. Do not add resource identifiers, addresses, names, secret values, quotas, protected URLs, evidence links, or console output.

```yaml
schema_version: 1
status: awaiting_operator_attestation
verified_at: null
project:
  dedicated_non_production: null
  billing_and_quotas_isolated: null
  required_apis_only: null
  primitive_roles_absent: null
oauth:
  internal_test_audience: null
  dedicated_ios_client: null
  scopes_match_client: null
pubsub:
  topic_in_test_project: null
  gmail_publisher_topic_scoped: null
  subscription_targets_test_convex_only: null
  retention_retry_and_cleanup_bounded: null
convex:
  deployment_isolated: null
  production_data_and_routes_absent: null
  runtime_configuration_verified: null
notifications:
  non_production_identity_and_credentials: null
  production_devices_unreachable: null
github:
  protected_environment_verified: null
  required_reviewer_and_no_self_review: null
  default_branch_only: null
  secrets_restricted_to_approved_job: null
operations:
  secret_inventory_and_owners_recorded: null
  rotation_quotas_and_cleanup_recorded: null
  repository_exposure_reviewed: null
readiness:
  synthetic_oauth_completed: null
  gmail_watch_and_push_completed: null
  redacted_evidence_reviewed: null
  production_target_negative_check_passed: null
  authorizer_role: null
```

The protected workflow must eventually find exactly one readiness artifact, parse only this schema, reject unknown, missing, duplicate, or malformed fields, and fail closed unless `schema_version` is `1`, `status` is `ready`, `verified_at` is a valid ISO 8601 UTC timestamp, `authorizer_role` is non-identifying, and every Boolean is `true`. Until issue #304 supplies that workflow, the record is a human-reviewed release prerequisite and does not authorize agent access to external systems.

## Handoff after readiness

The authorized operator may give the redacted record to the maintainer implementing issue #304. That workflow must retain the protected, serialized, credential-brokered boundary from [ADR 0041](adr/0041-broker-provider-compatibility-through-protected-workflows.md) and emit only redacted Mail Test Evidence.

This runbook implements the repository-side handoff for [issue #303](https://github.com/unwired-dev/product/issues/303). External project, Convex, GitHub environment, notification, and secret provisioning and the protected attestation remain human actions.
