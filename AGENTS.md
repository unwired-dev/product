# Agent guide

## Start here

The checkout contains the SwiftUI and Mac Catalyst prototype and the Expo mock
Inbox in `apps/mobile`, plus the AppKit React Native Mac mock Inbox in
`apps/macos`. Follow [Expo setup](docs/expo-client.md) for the root workspace setup
and [Mac setup](docs/macos-client.md) for the desktop host.

Read the issue, [documentation index](docs/README.md), relevant
[domain index](GLOSSARY.md), its relevant topic glossary, and the nearest nested
`AGENTS.md` before editing.
Client guides contain product behavior, setup and validation. Architecture lives
in separate files reserved for the review agent under the workflow below.

## Implementation and review

Follow the [implementation and review workflow](docs/agents/implementation-review.md)
for every implementation, including later implementation fixes.

- The implementer never reads repository architecture documentation, including
  `docs/architecture/`, ADRs, `.patterns/`, and the reviewer-only sources listed
  in the implementation and review workflow.
  This role boundary takes precedence over architecture-reading instructions in
  other repository guides or skills.
- After implementing and running the relevant checks, spawn a separate review
  agent with explicit `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, and
  `fork_turns: "none"`, regardless of the implementer's model or reasoning effort.
- The review agent reads the relevant architecture docs, reviews the complete
  implementation, fixes validated issues itself, and verifies its changes.
  The implementer pauses writes while the reviewer owns the checkout and waits
  for its final report before delivering the work.
- Reviewers do not spawn another implementation reviewer for their own fixes.
  Any subsequent implementer edits require another review by the pinned agent.

## Work

- Preserve unrelated working-tree changes and keep edits within the requested scope.
- When changing product terminology or `GLOSSARY.md`, follow the
  [domain documentation policy](docs/agents/domain.md). Keep definitions in their
  owning topic and the root glossary file as a reading index.
- Use the mise-managed toolchain and the nearest `package.json` package-manager
  version. Follow [setup instructions](README.md#local-development).
- Use one root workspace and lockfile with scoped native catalogs under
  the workspace setup in [Expo setup](docs/expo-client.md#dependencies-and-coding-rules).
- Put temporary probes in `scratchpad/`, run TypeScript with plain Node 24,
  and remove task-owned probes afterward.
- Invoke `task-observer` for task-oriented work and consult relevant open skill
  observations. Resolve skills through the session catalogue.

## Verify

Follow the [testing policy](docs/agents/testing.md) and
[validation commands](README.md#validation).

- Prefer integration tests that exercise real collaborating modules and observable
  outcomes. Prefer end-to-end tests for complete user journeys in the running app.
- Write the minimum unit tests needed for risks that integration or E2E tests
  cannot cover reliably or efficiently. Do not add a test for every function.
- Every test must protect a named behavior or failure risk and fail when that
  behavior breaks. Avoid implementation-detail assertions, internal mock call counts,
  trivial checks and duplicating the same evidence across test layers.
- Keep scenarios deterministic and isolated. Mock external boundaries where
  necessary; distinguish mocked journeys from real integration evidence.
- Retire tests only with replacement coverage or a reason their protected behavior
  no longer exists. Docs-only changes need formatting and link checks.

For native builds and interaction tests, follow the
[native validation guide](docs/agents/native-validation.md) and
[Expo commands](docs/expo-client.md#validate). The replacement targets iOS,
iPadOS, and macOS 27. Record unavailable checks as deferred; they remain required
before release. Legacy Swift checks are outside the maintained CI scope.

## Deliver

- Update affected documentation with behavior, setup, command, or workflow changes.
- Add a changeset for runtime behavior or exported API/type changes. Documentation,
  tests, and internal refactors may omit one.
- Track work in [GitHub Issues](docs/agents/issue-tracker.md) using the
  [triage labels](docs/agents/issue-tracker.md#triage-labels) and native blocking dependencies.
- Open PRs ready for review and reference their issue. Independently validate
  feedback, record the disposition, and resolve handled conversations, including
  deferred work. Keep reviewer and CI completion gates independent.
- Before PR babysitting, follow the
  [repository policy](docs/agents/pull-request-babysitting.md).
- Report verification results and unavailable checks accurately.

## Effect

Before writing or reviewing TypeScript, read the
[Effect conventions](docs/agents/effect.md): where Effect is required, and how
boundaries, errors, services and runtimes are written. For service definitions,
also read [Define Effect services](docs/agents/effect-services.md).
Before writing Effect code,
read `node_modules/effect/AGENTS.md` **completely** and follow its links; search
`node_modules/effect/src` for APIs the guides do not cover.
