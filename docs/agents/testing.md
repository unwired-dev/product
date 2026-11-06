# Testing strategy

Prefer integration and end-to-end tests. Keep unit tests to the minimum needed
for specific risks those layers cannot cover reliably or efficiently. Choose
tests for confidence in real behavior and useful failure diagnosis, with
proportionate execution and maintenance cost.

Keep scenarios deterministic and isolated.

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
the real Persistent Inbox store and verify the displayed detail or unavailable route.
The native E2E runner verifies packaged launch, message selection and back
navigation. A rendered component test is not a native E2E test.

For native navigation and presentation changes, follow the
[early interaction check](native-components.md#exceptions-and-review) before
expanding the implementation. Component tests can protect application state and
action ordering, but keyboard, focus, gesture cancellation and presenter behavior
need native evidence. Where an event source is substituted, deliver events only
to current subscribers and honor listener removal; a mock must not make an
unmounted or dismissed interaction appear live.

For Convex, exercise public backend operations with the test database and
identity context, checking stored state and authorization outcomes rather than
mocking each internal helper.

[Deterministic Mock Mail Sessions](../mock-mail-sessions.md) supply synthetic
identity, mail and assistance providers for app journeys. Linux CI exercises
both external runners with tool stubs, including ownership, cleanup, production-build
rejection and zero-test failure. These are runner contracts, not native evidence.
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

A regression test is evidence only once it fails on the unfixed code: run it
against the base or with the fix reverted and record that failure. When a
reported failure cannot be observed directly, reproduce it as a failing
integration test at the nearest real seam that produces the reported state, and
name that seam in the PR.

A test keeps the documented expectation when newly observed behavior disagrees
with the feature guide or an open issue.

Record each check command's exit status, including separately when batching,
with skipped-test counts and reasons. An output tail or a pipe's final command
does not establish the check's status. Unavailable or skipped checks do not prove their behavior. When a
skip reason describes the current environment, enable the check or report it
as unexecuted.

Run the smallest meaningful checks first. Broaden validation when shared configuration,
workspace wiring, cross-package behavior, or a high-consequence boundary changes.

## Execution environment

Required tests should run in the environment needed to exercise their contract.
Keep tests unchanged when the sandbox blocks them; rerun outside it.

Automated native checks follow the
[resource ownership and cleanup policy](native-validation.md).

## Current checks

The [workflow files](../../.github/workflows/) define the automated checks;
[Expo validation](../expo-client.md#validate) documents local commands and their
limits. Pull requests that change only `docs/`, `.agents/` and Markdown files skip
the Mobile and Mac jobs, and GitHub accepts the skipped required `Expo mobile`
check. TypeScript and Fallow still run, and pushes to `main` run every job. Track
unavailable native and protected checks in
[platform qualification](../qualification/expo-react-native-client.md); they
remain required before release.

## Consolidation and retirement

Prefer one canonical contract plus tests for each implementation's genuine
differences; table-driven cases may replace named permutations when failures
stay diagnosable. Retire a test only when it duplicates a canonical contract,
asserts an implementation detail, depends on incidental scheduling that
deterministic coverage replaces, or protects superseded behavior. The PR names
the risk and its retained coverage, or why the risk no longer exists. Keep
privacy, identity-isolation, data-loss and duplicate-delivery coverage. Do not
run blanket purges or set reduction targets.
