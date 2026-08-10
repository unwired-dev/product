# Mail test environment implementation plan

Status: the secure GreenMail smoke foundation, disposable Mail Test Device, Apple app bootstrap, Synthetic Test Message visibility assertion, on-demand System Categorization scenario, and persistent Manual Mail Sandbox are available; broader scenarios, the required pull-request gate, and provider compatibility remain planned.

## Goal

Give developers and autonomous agents a safe, repeatable way to exercise the Core Mail Loop with Synthetic Test Messages through the production mail interface, local persistence, and provider adapters. The environment has two complementary tiers:

| Tier                        | Purpose                                                                                                     | Gate                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Local Mail Test Environment | Deterministic everyday development and pull-request testing through IMAP and SMTP                           | Planned pull-request Core Mail Loop test     |
| Provider Compatibility Run  | Gmail-specific compatibility through real Gmail APIs, labels, history, watch registration, and push routing | Nightly, manual, and required before release |

The local tier does not claim Gmail compatibility. The Gmail tier does not replace deterministic pull-request coverage.

## Available and planned interfaces

The target repository-owned TypeScript Mail Test Harness will have no TypeScript package dependencies. The planned environment will still require pnpm, Node 24, checksum-pinned GreenMail, mise-managed Java 21, and mise. It will expose these target interfaces through `pnpm`:

```sh
pnpm mail:test run core-mail-loop --json
pnpm mail:test run categorization --json
pnpm mail:test sandbox start --scenario core-mail-loop
pnpm mail:test sandbox status
pnpm mail:test sandbox inject
pnpm mail:test sandbox reset
pnpm mail:test sandbox stop
pnpm mail:test doctor
```

The implemented foundation currently supports:

```sh
mise exec -- pnpm mail:test run core-mail-loop --json
mise exec -- pnpm mail:test run categorization --json
mise exec -- pnpm mail:test sandbox start --scenario core-mail-loop
mise exec -- pnpm mail:test sandbox status
mise exec -- pnpm mail:test sandbox inject
mise exec -- pnpm mail:test sandbox reset
mise exec -- pnpm mail:test sandbox stop
mise exec -- pnpm mail:test doctor
```

`run core-mail-loop` verifies the checksum-pinned GreenMail artifact, starts
run-scoped loopback IMAPS and SMTPS endpoints with a generated certificate,
seeds and reads synthetic mail, submits and verifies a second raw message,
creates an owned Mail Test Device using the iPhone 17 Simulator device type,
installs the generated public certificate authority only there, and launches
the test-only app bootstrap. Its XCUITest asserts that the Synthetic Test
Message subject appears through the production mail interface.
The command then emits redacted JSON evidence and removes only its
ownership-verified process, simulator, and run directory.
`run categorization` sends six source-controlled Synthetic Test Messages
through the same production IMAP synchronization and System Categorization
path. Five fixtures verify visible People, Orders, Newsletters & Promotions,
Invites, and Flights assignments; one automated ambiguous fixture verifies
that the client leaves low-confidence messages in Uncategorized State. Its JSON output names
only fixture slugs, expected category labels, and pass status, never fixture
subjects, senders, bodies, or message identifiers.
`doctor` reports stale or ambiguous run-owned directories without mutating them.

`run` owns one disposable Mail Test Run from creation through cleanup. `sandbox`
owns one persistent Manual Mail Sandbox rooted at
`~/.cache/unwired-mail-test/manual-sandbox`, separate from all Mail Test Runs.
`sandbox start` creates dynamic loopback IMAPS and SMTPS endpoints, a retained
certificate, a uniquely named persistent Mail Test Device, and a Debug-only
Mail Test Bootstrap app. It seeds the canonical synthetic Core Mail Loop
fixture and leaves the app and GreenMail available for exploration.
`sandbox status` reports the owned process, exact simulator, and loopback
connection details as JSON without credentials or message content. `inject`
idempotently restores the canonical synthetic fixture without removing other
sandbox mail. `reset` purges only the local sandbox mailbox, restores that
fixture, clears the test app's sandboxed local data, and relaunches it. `stop`
is idempotent and removes the GreenMail process, simulator, and state directory
only after exact ownership checks.

If `status` reports `stale`, run `sandbox stop` before starting again. If an
ownership record, process marker, simulator name, or UDID does not match,
cleanup fails closed and preserves the remaining resources for inspection.
`doctor` continues to report disposable run directories only.

Machine-readable output goes to standard output when `--json` is present. Human diagnostics go to standard error so agents can parse results without scraping logs.

## Local architecture

For each Mail Test Run, the harness:

1. Validates the selected Mailbox Scenario. The harness currently accepts `core-mail-loop` and `categorization`.
2. Resolves a checksum-pinned GreenMail standalone artifact and mise-managed Java 21.
3. Allocates dynamic loopback endpoints. Implemented for IMAPS and SMTPS.
4. Generates a short-lived certificate authority and hostname-valid TLS certificate, then configures IMAPS and SMTPS with TLS 1.2 or newer. Implemented in the TypeScript harness.
5. Creates a fresh Mail Test Device using the iPhone 17 Simulator device type and installs the generated public certificate authority only there. Implemented in the TypeScript harness.
6. Starts GreenMail, provisions synthetic users, and seeds the scenario. Implemented in the TypeScript harness.
7. Builds and launches the explicitly test-only app configuration with Mail Test Bootstrap launch configuration. Implemented for the seeded mailbox presentation path.
8. Runs the selected focused XCUITest and independently inspects server-visible mailbox state. Implemented for Synthetic Test Message visibility, visible System Categorization assignments, the ambiguous uncategorized case, and the existing IMAPS smoke assertions; broader mail actions remain planned.
9. Emits Mail Test Evidence. Implemented for the `core-mail-loop` and `categorization` scenarios.
10. Deletes only resources proven to belong to the run by its Mail Test Ownership Record. Implemented in the TypeScript harness.

The Manual Mail Sandbox uses the same components but keeps its own UUID-suffixed
`Unwired Mail Manual Sandbox` simulator, mail state, certificate material, and
ownership record until explicitly reset or stopped. It never shares paths,
ports, processes, simulator naming, or cleanup records with automated runs.

## Application boundary

The TypeScript harness provisions the Mail Test Device and passes its run-scoped launch configuration. The Apple app owns `MailTestBootstrap` and the production mail path. The test-only build creates an isolated Test Product Account and pre-authorizes its assigned local Mailbox Connection without Sign in with Apple or Convex. It continues to use the production mail UI, local persistence, generic IMAP/SMTP adapter, Outbox, provider actions, and message rendering.

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
- `message-content`: plain text, HTML alternatives, Unicode, inline images, attachments, remote-image and tracking markers, and provider-tolerated, standards-valid edge cases.
- `categorization`: available on demand with People, Orders, Newsletters & Promotions, Invites, Flights, and one deliberately ambiguous fixture in Uncategorized State.
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

If ownership is missing, stale, or ambiguous, cleanup fails closed and reports the orphan. Simulator cleanup records the exact run-scoped Mail Test Device name before creation and reconciles it to the returned UDID. Manual-sandbox stop additionally requires the command line of the recorded PID to contain the exact sandbox argument-file path before sending a signal, and re-validates that match before any escalation to SIGKILL. It preserves its state directory if process or simulator cleanup fails. Cleanup must not kill by process name, delete simulators by a broad name match, reset a shared keychain, remove arbitrary temporary directories, or purge shared provider state.

## Continuous integration

A planned Apple pull-request gate will start the local environment and run `core-mail-loop` on a Mail Test Device using the iPhone 17 Simulator device type. The existing adapter, MailEngine, lint, format, and performance checks remain separate. The Core Mail Loop will be one focused UI gate; broader scenario permutations may run as service-level XCTest or on demand.

The protected Gmail workflow:

- runs nightly, by manual dispatch, and as a required pre-release check;
- uses one concurrency group so only one Provider Compatibility Run mutates the shared tenant at a time;
- starts from protected, pre-authorized test-user credentials and exercises token restoration and refresh;
- keeps initial Google consent as a manual check;
- returns redacted Mail Test Evidence to agents without exposing reusable credentials;
- treats nightly failures as regressions requiring triage, but does not block unrelated pull requests.

## Gmail provider tier

Gmail compatibility uses a dedicated synthetic-only Google Workspace Provider Test Tenant with at least two Provider Test Mailboxes and an internal OAuth application. A separate Provider Test Project owns its OAuth client, Gmail API quotas, Pub/Sub resources, and protected credentials. Production Google Cloud projects, quotas, push routes, and credentials are out of scope.

Human operators provision and attest the tenant through the [Gmail Provider Test Tenant runbook](gmail-provider-test-tenant.md). Provider Compatibility Runs must fail closed until the redacted readiness record reports verification of every required control by an authorized operator.

The automated push test proves real Gmail watch registration, Pub/Sub delivery, isolated Convex routing, and the exact APNs background-push payload. It then injects that exact payload into the Mail Test Device and verifies device-side incremental history synchronization. It does not claim live APNs coverage. Initial Google consent and live APNs delivery remain manual pre-release checks on an authorized physical test device.

## Delivery phases

### 1. Harness foundation (available)

- Java 21 is available through mise, and GreenMail is pinned by exact version and checksum.
- Lifecycle, dynamic endpoints, certificates, Mail Test Device ownership, ownership records, JSON output, and scenario validation are implemented.
- Verified: the smoke scenario starts, reports readiness, emits evidence, and cleans up its owned resources.

### 2. Local application path (partially available)

- Available: the test-only Product Account and Mailbox Connection bootstrap.
- Available: the `core-mail-loop` smoke scenario, accessibility identifiers, focused XCUITest target, and server assertions for Synthetic Test Message visibility.
- Planned: add the required pull-request CI gate.
- Current verification: `pnpm mail:test run core-mail-loop --json` passes locally, and release builds cannot compile or activate the bootstrap. CI gating remains planned.

### 3. Scenario breadth and sandbox (partially available)

- Available: the on-demand `categorization` corpus, production categorization path, visible assignments, ambiguous case, and redacted per-fixture evidence.
- Available: persistent start, status, idempotent synthetic injection, reset,
  and ownership-checked stop for `core-mail-loop`.
- Planned: add `message-content` and `incremental-arrival`,
  plus retained failure screenshots and broader evidence.
- Current verification: humans and agents can start, inspect, mutate, reset,
  and stop the local sandbox through supported commands only.

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
