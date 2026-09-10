# Agent guide

## Start here

The checkout contains the SwiftUI and Mac Catalyst prototype. The approved Expo
and native React Native Mac replacement is not implemented yet.

Read the issue, [documentation index](docs/README.md), relevant
[domain terms](CONTEXT.md), and the nearest nested `AGENTS.md` before editing.
Follow the replacement decisions in ADR 0059 through 0064, linked from the index.
Historical prototype plans do not expand the approved scope.

## Work

- Preserve unrelated working-tree changes and keep edits within the requested scope.
- Use the mise-managed toolchain and the nearest `package.json` package-manager
  version. Follow [setup instructions](README.md#local-development).
- Keep mobile and Mac dependency installations independent under
  [ADR 0064](docs/adr/0064-isolate-mobile-and-macos-native-dependencies.md).
- Put temporary probes in `scratchpad/`, run TypeScript with plain Node 24,
  and remove task-owned probes afterward.
- Invoke `task-observer` for task-oriented work and consult relevant open skill
  observations. Resolve skills through the session catalogue.

## Verify

Follow the [testing policy](docs/agents/testing.md) and
[validation commands](README.md#validation). Add tests for named risks and retire
tests only with replacement coverage or a reason their behavior no longer exists.
Docs-only changes need formatting and link checks.

For the Swift app or Apple CI, follow the
[Apple validation guide](docs/agents/apple-validation.md), including resource
ownership and host fallback. Keep required checks until replacements are verified.
The replacement targets iOS, iPadOS, and macOS 27. Native validation is deferred
while tooling is unavailable, but remains required before release.

## Deliver

- Update affected documentation with behavior, setup, command, or workflow changes.
- Add a changeset for runtime behavior or exported API/type changes. Documentation,
  tests, and internal refactors may omit one.
- Track work in [GitHub Issues](docs/agents/issue-tracker.md) using the
  [triage labels](docs/agents/triage-labels.md) and native blocking dependencies.
- Open PRs ready for review and reference their issue. Independently validate
  feedback, record the disposition, and resolve handled conversations, including
  deferred work. Keep reviewer and CI completion gates independent.
- Before PR babysitting, follow the
  [repository policy](docs/agents/pull-request-babysitting.md).
- Report verification results and unavailable checks accurately.
