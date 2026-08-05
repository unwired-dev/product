# Mail test environment implementation plan

Status: design agreed; implementation has not started.

## Goal

Give developers and autonomous agents a safe, repeatable way to exercise the Core Mail Loop with Synthetic Test Messages through the production mail interface, local persistence, and provider adapters. The environment has two complementary tiers:

| Tier | Purpose | Gate |
| --- | --- | --- |
| Local Mail Test Environment | Deterministic everyday development and pull-request testing through IMAP and SMTP | Required pull-request Core Mail Loop test |
| Provider Compatibility Run | Gmail-specific compatibility through real Gmail APIs, labels, history, watch registration, and push routing | Nightly, manual, and required before release |

The local tier does not claim Gmail compatibility. The Gmail tier does not replace deterministic pull-request coverage.

## Supported interfaces

The repository-owned, dependency-free TypeScript Mail Test Harness runs on Node 24 and is exposed through `pnpm`:

```sh
pnpm mail:test run core-mail-loop --json
pnpm mail:test sandbox start --scenario core-mail-loop
pnpm mail:test sandbox status
pnpm mail:test sandbox inject --message follow-up
pnpm mail:test sandbox reset --scenario message-content
pnpm mail:test sandbox stop
pnpm mail:test doctor
```

`run` owns a disposable environment from creation through cleanup. `sandbox` manages a separately named persistent environment for human exploration. `doctor` reports ownership-verified orphaned resources and provides explicit recovery commands; it never performs broad process, simulator, or filesystem cleanup.

Machine-readable output goes to standard output when `--json` is present. Human diagnostics go to standard error so agents can parse results without scraping logs.

## Local architecture

For each Mail Test Run, the harness:

1. Validates the selected Mailbox Scenario.
2. Resolves a checksum-pinned GreenMail standalone artifact and mise-managed Java 21.
3. Allocates dynamic loopback endpoints.
4. Generates a short-lived certificate authority and hostname-valid TLS certificate, then configures IMAPS and SMTPS with TLS 1.2 or newer.
5. Creates a fresh iPhone 17 Simulator and installs the generated public certificate authority only into that Mail Test Device.
6. Starts GreenMail, provisions synthetic users, and seeds the scenario.
7. Builds and launches the explicitly test-only app configuration with Mail Test Bootstrap launch configuration.
8. Runs the Core Mail Loop XCUITest and independently inspects server-visible mailbox state.
9. Emits Mail Test Evidence.
10. Deletes only resources proven to belong to the run by its Mail Test Ownership Record.

The Manual Mail Sandbox uses the same components but keeps its own named simulator, mail state, certificate material, and ownership record until explicitly reset or stopped. It never shares state with automated runs.

## Application boundary

The test-only build creates an isolated Test Product Account and pre-authorizes its assigned local Mailbox Connection without Sign in with Apple or Convex. It continues to use the production mail UI, local persistence, generic IMAP/SMTP adapter, Outbox, provider actions, and message rendering.

The test bootstrap:

- exists only behind a dedicated test compilation condition and is absent from release builds;
- accepts startup configuration through launch arguments or environment;
- does not seed messages or reset state;
- exposes no test control server, fixture loader, provider bypass, or debug backdoor.

Sign in with Apple, Convex Product Account authentication, and initial provider consent retain separate tests and manual checks.

## Scenario corpus

Each source-controlled scenario is a directory containing a declarative JSON manifest, raw `.eml` messages, and referenced synthetic assets. The manifest defines users, mailboxes, placement, flags, ordering, actions, semantic expectations, server-state expectations, and explicit provider-specific capability differences.

Local and provider tiers consume the same scenario corpus. Scenario content must never derive from personal or production mail, even when anonymized.

V1 contains four scenario families:

- `core-mail-loop`: initial sync, reading, read state, organization, compose, send, reply, and Sent verification. This is the required pull-request XCUITest.
- `message-content`: plain text, HTML alternatives, Unicode, inline images, attachments, remote-image and tracking markers, and malformed-but-displayable mail.
- `categorization`: People, Orders, Newsletters & Promotions, Invites, and Flights.
- `incremental-arrival`: new messages and thread updates after initial synchronization, including local refresh and Gmail history/push behavior.

Protocol fault matrices remain in the existing MailEngine and adapter contract tests instead of being duplicated as Mailbox Scenarios.

## Assertions and evidence

Correctness requires both:

- semantic accessibility assertions against user-visible app state; and
- independent server or provider assertions against mailbox state.

Screenshots are diagnostic evidence rather than pixel-perfect golden baselines.

Each automated run produces redacted structured results, scenario identity, before-and-after mailbox snapshots, GreenMail or provider logs, application and test logs, XCTest results, cleanup status, and failure screenshots. Credentials, OAuth tokens, certificate private keys, and unredacted provider identifiers are excluded. Successful local evidence may be removed after the run; failed local and CI evidence is retained for diagnosis.

## Cleanup safety

Every owned process, simulator UDID, endpoint, generated directory, certificate path, and run token is recorded in a Mail Test Ownership Record. Cleanup validates exact ownership immediately before mutation.

If ownership is missing, stale, or ambiguous, cleanup fails closed and reports the orphan. It must not kill by process name, delete simulators by a broad name match, reset a shared keychain, remove arbitrary temporary directories, or purge shared provider state.

## Continuous integration

The Apple pull-request job starts the local environment and runs `core-mail-loop` on the iPhone 17 Simulator. The existing adapter, MailEngine, lint, format, and performance checks remain separate. The Core Mail Loop is one focused UI gate; broader scenario permutations may run as service-level XCTest or on demand.

The protected Gmail workflow:

- runs nightly, by manual dispatch, and as a required pre-release check;
- uses one concurrency group so only one Provider Compatibility Run mutates the shared tenant at a time;
- starts from protected, pre-authorized test-user credentials and exercises token restoration and refresh;
- keeps initial Google consent as a manual check;
- returns redacted Mail Test Evidence to agents without exposing reusable credentials;
- treats nightly failures as regressions requiring triage, but does not block unrelated pull requests.

## Gmail provider tier

Gmail compatibility uses a dedicated synthetic-only Google Workspace Provider Test Tenant with at least two mail users and an internal OAuth application. A separate Provider Test Project owns its OAuth client, Gmail API quotas, Pub/Sub resources, and protected credentials. Production Google Cloud projects, quotas, push routes, and credentials are out of scope.

The automated push test proves real Gmail watch registration, Pub/Sub delivery, isolated Convex routing, and the exact APNs background-push payload. It then injects that exact payload into the Mail Test Device and verifies device-side incremental history synchronization. It does not claim live APNs coverage. Initial Google consent and live APNs delivery remain manual pre-release checks on an authorized physical test device.

## Delivery phases

### 1. Harness foundation

- Add Java 21 to mise and pin GreenMail by exact version and checksum.
- Implement lifecycle, dynamic endpoints, certificates, owned simulators, ownership records, JSON output, and scenario validation.
- Verify: a smoke scenario starts, reports readiness, emits evidence, and cleans up without app changes.

### 2. Local application path

- Add the test-only Product Account and Mailbox Connection bootstrap.
- Add the `core-mail-loop` scenario, accessibility identifiers, XCUITest target, and server assertions.
- Add the required pull-request CI gate.
- Verify: `pnpm mail:test run core-mail-loop --json` passes locally and in CI with release builds unable to compile or activate the bootstrap.

### 3. Scenario breadth and sandbox

- Add `message-content`, `categorization`, and `incremental-arrival`.
- Add the persistent sandbox commands, evidence retention, failure screenshots, and developer documentation.
- Verify: humans and agents can start, inspect, mutate, reset, diagnose, and stop the sandbox through supported commands only.

### 4. Gmail compatibility

- Provision the Provider Test Tenant, Provider Test Project, protected secrets, and isolated Convex resources.
- Implement the shared-scenario Gmail backend and serialized workflow.
- Add relay-output verification, device payload injection, and the physical-device checklist.
- Verify: nightly and manual runs produce redacted evidence, clean only their run-scoped provider state, and cannot reach production resources.

## Definition of done

The environment is complete when all four phases are documented and runnable, the local Core Mail Loop is a required pull-request check, the protected Gmail workflow runs on its agreed cadence, test-only application code is absent from release builds, no personal or production message content is accepted, evidence is redacted, and uncertain cleanup fails closed.

## Decisions

- [ADR 0032: Use only synthetic mail in test environments](adr/0032-use-only-synthetic-mail-in-test-environments.md)
- [ADR 0033: Bootstrap mail tests without external Product Account authentication](adr/0033-bootstrap-mail-tests-without-external-product-authentication.md)
- [ADR 0034: Use GreenMail standalone for local mail testing](adr/0034-use-greenmail-standalone-for-local-mail-testing.md)
- [ADR 0035: Isolate mail testing in harness-owned simulators](adr/0035-isolate-mail-testing-in-harness-owned-simulators.md)
- [ADR 0036: Generate mail-test certificates per environment](adr/0036-generate-mail-test-certificates-per-environment.md)
- [ADR 0037: Keep mail-test control outside the app](adr/0037-keep-mail-test-control-outside-the-app.md)
- [ADR 0038: Use a dedicated Google Workspace test tenant](adr/0038-use-a-dedicated-google-workspace-test-tenant.md)
- [ADR 0039: Isolate Gmail testing in a Provider Test Project](adr/0039-isolate-gmail-testing-in-a-provider-test-project.md)
- [ADR 0040: Split automated Gmail push testing at APNs](adr/0040-split-automated-gmail-push-testing-at-apns.md)
- [ADR 0041: Broker provider compatibility through protected workflows](adr/0041-broker-provider-compatibility-through-protected-workflows.md)
- [ADR 0042: Fail closed when mail-test cleanup ownership is uncertain](adr/0042-fail-closed-when-mail-test-cleanup-ownership-is-uncertain.md)
