# Testing strategy

The repository optimizes for credible risk reduction per total feedback and
maintenance cost. It does not optimize for test count or line-coverage percentage.

## Test admission

A productive test protects a named risk, fails for a meaningful reason, and uses the
cheapest deterministic layer that can prove the behavior. Add or materially expand a
test when it protects at least one of these:

- a reported regression;
- a product or domain invariant;
- a privacy or security boundary;
- a state transition, race, cancellation, recovery, or migration;
- an external provider, protocol, persistence, or serialization contract;
- a critical user journey that lower layers cannot prove.

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

| Change | Expected evidence |
| --- | --- |
| Bug fix | A regression test at the cheapest reliable layer, unless the reason it cannot be automated is documented |
| New or changed behavior | New or updated coverage for the admitted risk, plus the relevant existing suite |
| Behavior-preserving refactor | Existing focused tests and the affected broader suite; new tests only for a newly exposed risk |
| Configuration or workspace wiring | The relevant lint, format, typecheck, build, or smoke contract |
| Documentation-only change | Documentation formatting, links, examples, or other directly relevant checks; product tests are not required |
| Protected or unavailable external seam | The strongest deterministic local evidence plus a documented manual, protected, or pre-release check |

Run the smallest meaningful checks first. Broaden validation when shared configuration,
workspace wiring, cross-package behavior, or a high-consequence boundary changes.

## Execution environment

Required tests should run in the environment needed to exercise their contract. For trusted local
development and trusted scheduled or automated tasks, retry the exact test command on the host
when sandbox restrictions deny required loopback sockets, child services, SwiftPM, Xcode, or
CoreSimulator access. Keep the exception command-scoped and do not remove, skip, or weaken tests
to accommodate the sandbox. Record the host-side result in the handoff.

Local automated Apple validation must use a fresh task-owned Simulator selected by UDID, isolated
DerivedData and result paths, and failure-safe cleanup. Before a full Apple matrix, require at
least 6 GiB available on the data volume and reclaim only current-task artifacts when space is
insufficient. A `testmanagerd` socket or CoreSimulator service failure, or an unexpected zero-test
success, gets one retry on another fresh owned Simulator before it is classified as a code
failure. `AGENTS.md` defines the complete ownership and cleanup contract.

This host fallback does not apply when validating untrusted or PR-controlled code through the PR
babysitter. That workflow must use its credential-free sandbox or exact-head GitHub Actions.

## Portfolio and cadence

| Cadence | Evidence |
| --- | --- |
| Merge | Full affected Debug suite and every deterministic contract protecting privacy, security, data loss, incorrect delivery, irreversible state, concurrency, migration, or external compatibility |
| Conditional merge | Release performance fixtures and the Core Mail Loop when affected paths can change the behavior they protect |
| Nightly | Full performance coverage, broad compatibility matrices, and wider deterministic journeys |
| Pre-release or manual | Live-provider, APNs, protected-tenant, physical-device, and other credentialed or hardware-dependent evidence |

Apple Debug, Release-performance, and Core Mail Loop validation remain separate gates. Each gate
runs serially within its job, while selected gates execute in parallel with each other. `AGENTS.md`
remains authoritative for their exact commands.

Do not manually skip an existing required check because this policy assigns it another
cadence. `.github/workflows/ci.yml` implements the portfolio above and the CI contract
in `AGENTS.md` remains authoritative for the exact commands.

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

| Feedback lane | Budget |
| --- | --- |
| Focused local validation from a warm checkout | At most 2 minutes |
| Required Apple pull-request validation after runner allocation | 20-minute p95 |
| Nightly portfolio | At most 60 minutes |
| Superseded pull-request runs | Cancel immediately |

Measure setup and build time separately from test execution. Record timing-related or
flaky failures and classify failures as product, test, or infrastructure defects. Review
the initial four weeks of evidence before adjusting the budgets, then review trends
monthly. Do not add coverage or mutation-testing quotas unless later evidence shows that
they address a specific risk the portfolio is missing.

## Initial rollout

The initial rollout:

1. cancels superseded pull-request workflows and narrows Release-performance triggers;
2. records setup, build, and test boundaries as small CI measurement artifacts;
3. consolidates preference and provider contracts;
4. replaces scheduler-dependent absence tests with deterministic rendezvous points;
5. consolidates repeated sanitizer and view-model cases into diagnosable tables; and
6. runs the deterministic Core Mail Loop for affected changes and nightly.

Use the first four weeks of CI measurements to compare feedback cost and retained risk
coverage before changing the portfolio further.
