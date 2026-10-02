# Mail test environment: architecture notes

Reviewer-only companion to [docs/mail-test-environment.md](../mail-test-environment.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Local architecture

For each Mail Test Run, the harness:

1. Validates the selected Mailbox Scenario. The harness currently accepts `core-mail-loop`, `categorization`, `incremental-arrival`, and `message-content`.
2. Resolves a checksum-pinned GreenMail standalone artifact and mise-managed Java 21.
3. Allocates dynamic loopback endpoints. Implemented for IMAPS and SMTPS.
4. Generates a short-lived certificate authority and hostname-valid TLS certificate, then configures IMAPS and SMTPS with TLS 1.2 or newer. Implemented in the TypeScript harness.
5. Creates a fresh Mail Test Device using the iPhone 17 Simulator device type and installs the generated public certificate authority only there. Implemented in the TypeScript harness.
6. Starts GreenMail, provisions synthetic users, and seeds the scenario. Implemented in the TypeScript harness.
7. Builds and launches the explicitly test-only app configuration with Mail Test Bootstrap launch configuration. Implemented for the seeded mailbox presentation path.
8. Runs the selected focused XCUITest and independently inspects server-visible mailbox state. Implemented for message opening, capability-aware read, archive, move, and trash actions, compose, Outbox admission, SMTP completion, recipient delivery, Sent identity, reply headers, duplicate prevention, visible reply-thread placement, message-content semantic and server invariants, visible System Categorization assignments, the ambiguous uncategorized case, incremental arrival and thread reconciliation, and the existing IMAPS smoke assertions.
9. Emits Mail Test Evidence. Implemented for the `core-mail-loop`, `categorization`, `incremental-arrival`, and `message-content` scenarios.
10. Deletes only resources proven to belong to the run by its Mail Test Ownership Record. Implemented in the TypeScript harness.

The Manual Mail Sandbox uses the same components but keeps its own UUID-suffixed
`Unwired Mail Manual Sandbox` simulator, mail state, certificate material, and
ownership record until explicitly reset or stopped. It never shares paths,
ports, processes, simulator naming, or cleanup records with automated runs.

## Application boundary

The TypeScript harness provisions the Mail Test Device and passes its run-scoped launch configuration. The Apple app owns `MailTestBootstrap` and the production mail path. The test-only build creates an isolated Test Product Account and pre-authorizes its assigned local Mailbox Connection without Sign in with Apple or Convex. It continues to use the production mail UI, local persistence, generic IMAP/SMTP adapter, Outbox, provider actions, and message rendering.

## Delivery phases

### 1. Harness foundation (available)

- Java 21 is available through mise, and GreenMail is pinned by exact version and checksum.
- Lifecycle, dynamic endpoints, certificates, Mail Test Device ownership, ownership records, JSON output, and scenario validation are implemented.
- Verified: the smoke scenario starts, reports readiness, emits evidence, and cleans up its owned resources.

### 2. Local application path (available)

- Available: the test-only Product Account and Mailbox Connection bootstrap.
- Available: the `core-mail-loop` scenario, stable compose/reply accessibility identifiers, focused XCUITest steps, and independent recipient-mailbox, Sent Mailbox, duplicate, and Stable Thread Identity assertions.
- Available: the Core Mail Loop Scheduled Send deterministic selection and visible two-mode Send Later assertion. Release remains gated on protected provider compatibility evidence.
- Standards-Based Mailbox Connections derive send, reply, and Provider Mail Actions from each connection's advertised capabilities. Unsupported connections report those steps as `unavailable`; evidence verifies that the visible client creates no Outbox handoff, recipient delivery, or Sent Mailbox copy and leaves IMAP state unchanged.
- Available: the `core-mail-loop` scenario, stable accessibility identifiers, focused XCUITest steps, and independent server assertions for opening, read state, archive, move, and trash.
- Available: issue #280 records passing iCloud Mail and Fastmail certification, so Standards-Based Mailbox Connections are enabled for externally distributed Release builds with the accepted SwiftMail 1.11.0 pin.
- Available: the on-demand `message-content` raw-message corpus, visible semantic assertions, remote-content connection beacon, and before-and-after IMAP invariants.
- Available: the affected-path pull-request and nightly Core Mail Loop gate with redacted failure diagnostics and XCTest result bundles.
- Current verification: `pnpm mail:test run core-mail-loop --json` and `pnpm mail:test run message-content --json` run locally, and release builds cannot compile or activate the bootstrap.

### 3. Scenario breadth and sandbox (partially available)

- Available: the on-demand `categorization` corpus, production categorization path, visible assignments, ambiguous case, and redacted per-fixture evidence.
- Available: the on-demand `incremental-arrival` corpus, TypeScript Mail Test
  Harness milestone coordination, staged injection, and IMAP observation, plus
  the Apple XCUITest target's initial visibility, production repeated-refresh
  path, and visible presentation assertions, with preserved initial state and
  phase-specific redacted evidence.
- Available: persistent start, status, idempotent synthetic injection, reset,
  and ownership-checked stop for `core-mail-loop`.
- Available: retained Core Mail Loop failure screenshots through XCTest result bundles; broader scenario evidence remains on demand.
- Current verification: humans and agents can start, inspect, mutate, reset,
  and stop the local sandbox through supported commands only.

### 4. Gmail compatibility (deferred release gate)

- Provision the Provider Test Tenant, Provider Test Project, protected secrets, and isolated Convex resources.
- Implement the shared-scenario Gmail backend and serialized workflow.
- Add relay-output verification, device payload injection, and the physical-device checklist.
- Verify: nightly and manual runs produce redacted evidence, clean only their run-scoped provider state, and cannot reach production resources.

## Decisions

- [ADR 0032: Use only synthetic mail in test environments](../adr/0032-use-only-synthetic-mail-in-test-environments.md)
- [ADR 0033: Bootstrap mail tests without external Product Account authentication](../adr/0033-bootstrap-mail-tests-without-external-product-authentication.md)
- [ADR 0034: Use GreenMail standalone for local mail testing](../adr/0034-use-greenmail-standalone-for-local-mail-testing.md)
- [ADR 0035: Isolate mail testing in harness-owned simulators](../adr/0035-isolate-mail-testing-in-harness-owned-simulators.md)
- [ADR 0036: Generate mail-test certificates per environment](../adr/0036-generate-mail-test-certificates-per-environment.md)
- [ADR 0037: Keep mail-test control outside the app](../adr/0037-keep-mail-test-control-outside-the-app.md)
- [ADR 0038: Use a dedicated Google Workspace test tenant](../adr/0038-use-a-dedicated-google-workspace-test-tenant.md)
- [ADR 0039: Isolate Gmail testing in a Provider Test Project](../adr/0039-isolate-gmail-testing-in-a-provider-test-project.md)
- [ADR 0040: Split automated Gmail push testing at APNs](../adr/0040-split-automated-gmail-push-testing-at-apns.md)
- [ADR 0041: Broker provider compatibility through protected workflows](../adr/0041-broker-provider-compatibility-through-protected-workflows.md)
- [ADR 0042: Fail closed when mail-test cleanup ownership is uncertain](../adr/0042-fail-closed-when-mail-test-cleanup-ownership-is-uncertain.md)
- [ADR 0047: Stage mail-engine adoption before provider certification](../adr/0047-stage-mail-engine-adoption-before-provider-certification.md)
