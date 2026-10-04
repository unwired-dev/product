# Agent guide

## Start here

The checkout contains the SwiftUI and Mac Catalyst prototype and the Expo mock
Inbox in `apps/mobile`, plus the AppKit React Native Mac mock Inbox in
`apps/macos`. Set up the mise-managed toolchain and the nearest `package.json`
package-manager version with the [setup instructions](README.md#local-development),
then follow [Expo setup](docs/expo-client.md) for the root workspace, its single
lockfile and scoped native catalogs, and [Mac setup](docs/macos-client.md) for the
desktop host.

Read the issue, [documentation index](docs/README.md), relevant
[domain index](GLOSSARY.md), its relevant topic glossary, and the nearest nested
`AGENTS.md` before editing.

## Implementation and review

Follow the [implementation and review workflow](docs/agents/implementation-review.md)
for every implementation, including later implementation fixes.

- The implementer never reads repository architecture documentation, including
  `docs/architecture/`, ADRs, `.patterns/`, and the reviewer-only sources listed
  in the workflow. This role boundary takes precedence over architecture-reading
  instructions in other repository guides or skills.
- Invoke the `ponytail` and `unlazy` skills before implementing, and follow both
  throughout the implementation.
- After implementing and running the relevant checks, spawn a separate review
  agent with explicit `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, and
  `fork_turns: "none"`, regardless of the implementer's model or reasoning effort.
  Use the workflow's Open Code Review delegation step inside that review agent.
  Pause writes until its final report; later implementer edits need another review.

## Work

- Preserve unrelated working-tree changes and keep edits within the requested scope.
- When changing product terminology or `GLOSSARY.md`, follow the
  [domain documentation policy](docs/agents/domain.md).
- Put temporary probes in `scratchpad/`, run TypeScript with plain Node 24,
  and remove task-owned probes afterward.
- Invoke `task-observer` for task-oriented work and consult relevant open skill
  observations. Resolve skills through the session catalogue.
- Use the `find-skills` skill to choose the correct skill for each job.

## Verify

Follow the [testing policy](docs/agents/testing.md) and
[validation commands](README.md#validation): prefer integration and E2E tests,
admit a test only for a named behavior or failure risk, and keep mocked journeys
distinct from real integration evidence.

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
[Effect conventions](docs/agents/effect.md) and, for service definitions,
[Define Effect services](docs/agents/effect-services.md). Before writing Effect
code, read `node_modules/effect/AGENTS.md` **completely** and follow its links;
search `node_modules/effect/src` for APIs the guides do not cover.
