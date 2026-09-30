# Testing strategy

Prefer integration and end-to-end tests. Keep unit tests to the minimum needed
for specific risks those layers cannot cover reliably or efficiently. Choose
tests for confidence in real behavior and useful failure diagnosis, with
proportionate execution and maintenance cost.

## Choose the test layer

- **Integration is the default for application behavior.** Exercise real
  collaborating modules through their public interfaces and assert observable
  results. Use real Effect services and layers, application logic, and the
  relevant adapters together. Substitute external boundaries such as provider
  responses or the clock when needed for deterministic scenarios; do not mock
  away the collaboration the test is meant to prove.
- **Prefer E2E for user journeys.** Drive the running app through user actions
  and verify visible outcomes across navigation, state and platform integration.
  Critical journeys deserve this coverage even when individual parts also have
  integration tests. Use a small set of representative success, failure and
  recovery journeys; test detailed permutations at the integration layer.
- **Use unit tests sparingly.** Add one only when an isolated algorithm,
  transformation or difficult edge case benefits from focused coverage that is
  impractical or unreliable through integration or E2E. Its name or surrounding
  context should make the protected risk clear. Do not create unit tests merely
  because a function, class or file exists.

For the Expo Inbox, a component integration test can select a message through
the real mailbox service and verify the displayed detail or unavailable route.
The native E2E runner verifies packaged launch, message selection and back
navigation. A rendered component test is not a native E2E test.

For Convex, exercise public backend operations with the test database and
identity context, checking stored state and authorization outcomes rather than
mocking each internal helper. As persistence, Gmail and Outbox slices land, add
integration coverage for their actual boundaries and E2E coverage for the
corresponding user journeys. These are testing requirements, not claims that
those replacement features already exist.

Deterministic Mock Mail Sessions can supply synthetic mail for app journeys.
They do not replace real persistence, native-binding or provider integration
evidence required by [ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).

## Test admission

Before adding a test, identify the behavior it protects, a plausible defect that
would make it fail, and the evidence missing from existing coverage. If those
answers are unclear, improve an existing test or omit the new one. Prefer
extending a meaningful scenario over adding several narrow assertions in
separate tests.

Add or materially expand a test when it protects at least one of these:

- a reported regression;
- a product or domain invariant;
- a privacy or security boundary;
- a state transition, race, cancellation, recovery, or migration;
- an external provider, protocol, persistence, or serialization contract;
- a critical user journey, including how its parts work together.

The following are not sufficient reasons by themselves:

- increasing a test count or coverage percentage;
- exercising a trivial accessor, constant, or framework behavior;
- asserting a mock, fixture, or internal call sequence instead of observable behavior;
- repeating a shared contract for another provider, feature, or layer without a
  distinct behavior;
- waiting on incidental scheduler timing when timing is not the contract.

## Proportionate verification

Every change receives evidence proportionate to its risk. A new test is not required
for every changed line.

| Change                                 | Expected evidence                                                                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Bug fix                                | An integration or E2E regression test; a focused unit test only under the exceptions above, or document why automation is unavailable |
| New or changed behavior                | Integration coverage and affected E2E journeys for the admitted risk, plus the relevant existing suite                                |
| Behavior-preserving refactor           | Existing focused tests and the affected broader suite; new tests only for a newly exposed risk                                        |
| Configuration or workspace wiring      | The relevant lint, format, typecheck, build, or smoke contract                                                                        |
| Documentation-only change              | Documentation formatting, links, examples, or other directly relevant checks; product tests are not required                          |
| Protected or unavailable external seam | The strongest deterministic local evidence plus a documented manual, protected, or pre-release check                                  |

Run the smallest meaningful checks first. Broaden validation when shared configuration,
workspace wiring, cross-package behavior, or a high-consequence boundary changes.

## Execution environment

Required tests should run in the environment needed to exercise their contract.
For trusted local development and trusted scheduled or automated tasks, use the
available host-execution or approval mechanism to retry the exact validation
command when sandbox restrictions deny required sockets, child services or
native tooling. Follow the session's permissions; if no permitted route exists,
report the check as unavailable. Keep host access command-scoped, use the pinned
toolchain, and report the host-side result. Do not weaken tests to accommodate
the sandbox.

This exception never applies to the PR babysitter workflow,
including trusted-base validation. Follow its
[credential-free isolation and remote-CI policy](pull-request-babysitting.md).
Automated native checks follow the
[resource ownership and cleanup policy](native-validation.md).

## Current checks and release evidence

The maintained checks cover the Expo and Mac apps, shared core/contracts and retained
Convex backend:

| Lane                | Evidence                                                                                                                                                |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CI: TypeScript      | Lint, formatting, types and tests for mobile, Mac and Convex with their workspace dependencies; Effect import-policy tests and agent workflow contracts |
| CI: Fallow          | Root unused-code and complexity audit                                                                                                                   |
| CI: Expo mobile     | Mobile Fallow scan, Expo compatibility, production Hermes export and bundle boundary checks                                                             |
| CI: Mac bundle      | Mac production JavaScript export, renderer inventory, shared source and native autolinking scope                                                        |
| CI: Expo native E2E | Real Keychain/encrypted-store checks, Expo Release build and iPhone/iPad relaunch journeys                                                              |
| Pre-release         | Real Gmail authorization and transport, encrypted persistence, credentials, APNs, accessibility, physical devices and native Mac qualification          |

The workflow files [CI](../../.github/workflows/ci.yml) and
[Mobile](../../.github/workflows/mobile.yml) and [Mac](../../.github/workflows/macos.yml) define the automated commands.
[Expo validation](../expo-client.md#validate) documents local commands and their
limits. The native E2E job runs the iPhone/iPad Inbox journey on hosted macOS;
no nightly validation matrix is currently configured. Legacy Swift jobs and the legacy mail harness
are excluded from primary CI by maintainer decision.

Add affected regression and contract checks as replacement slices land.
Deterministic Mock Mail Sessions must remain distinct from real integration
evidence under [ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
Retain coverage for privacy, identity isolation, data loss and duplicate delivery
when retiring the old client. Track unavailable native and protected checks in
[platform qualification](../qualification/expo-react-native-client.md); they
remain required before release.

## Consolidation and retirement

Prefer one canonical reusable contract plus tests for each implementation's genuine
differences. Table-driven or generated cases may replace many named permutations when
they preserve the invariant and leave failures diagnosable.

A test may be retired when it:

- duplicates a canonical contract at another layer or implementation;
- asserts an implementation detail or fixture rather than supported behavior;
- depends on incidental scheduling and deterministic coverage replaces it;
- protects behavior that has been explicitly superseded.

The pull request must identify the risk and either point to retained coverage or explain
why the risk no longer exists. Do not run blanket test purges or set a numeric reduction
target. Replace scheduler-sensitive absence checks with controlled clocks, explicit
synchronization, or observable state transitions before removing them.

## Feedback budgets and measurement

| Feedback lane                                            | Budget             |
| -------------------------------------------------------- | ------------------ |
| Focused local validation from a warm checkout            | At most 2 minutes  |
| Required pull-request validation after runner allocation | 20-minute p95      |
| Superseded pull-request runs                             | Cancel immediately |

These are feedback targets. The native E2E job has a 45-minute timeout to
accommodate a cold build; measure its actual duration against the PR target.
Measure setup and build time separately from test execution. Record timing-related or
flaky failures and classify failures as product, test, or infrastructure defects. Review
the initial four weeks of evidence before adjusting the budgets, then review trends
monthly. Do not add coverage or mutation-testing quotas unless later evidence shows that
they address a specific risk the portfolio is missing.
