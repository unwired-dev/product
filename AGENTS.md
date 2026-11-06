# Agent guide

## Start here

The maintained clients are Expo in `apps/mobile` and React Native macOS in
`apps/macos`. Set up the mise-managed toolchain and the nearest `package.json`
package-manager version with the [setup instructions](README.md#local-development),
then follow [Expo setup](docs/expo-client.md) and [Mac setup](docs/macos-client.md).

Before editing, read the issue, the [documentation index](docs/README.md), the
relevant entries of the [domain index](GLOSSARY.md) and the nearest nested
`AGENTS.md`. When the change touches an area with architecture notes or ADRs,
read those too: they explain why the code is shaped the way it is.

Follow the [implementation and review workflow](docs/agents/implementation-review.md):
implement, get one independent review, open a PR.

## Coding principles

- State the acceptance criteria and the checks that prove them before you start.
- Make the smallest complete change. Match existing style, preserve unrelated
  working-tree changes and remove only code made unused by this task.
- Packages are deep modules: read [packages/README.md](packages/README.md) before
  adding a package, an entry point or a cross-package import.
- For React, React Native or Expo UI, use the provided component first; see
  [native component selection](docs/agents/native-components.md). Animation,
  gestures, press feedback and haptics load the
  [animation skills](docs/agents/native-components.md#animation-skills).
- Write TypeScript by the [Effect conventions](docs/agents/effect.md) and, for
  services, [Define Effect services](docs/agents/effect-services.md). Before
  writing Effect code, read `node_modules/effect/AGENTS.md` and the guides it links.
- When changing product terminology or `GLOSSARY.md`, follow the
  [domain documentation policy](docs/agents/domain.md).
- Put temporary probes in `scratchpad/`, run TypeScript with plain Node 24,
  and remove them afterward.

## Design

[DESIGN.md](DESIGN.md) and the
[Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T)
Figma file define how the maintained clients look and behave.

- For design work, load the `impeccable` and `apple-design` skills.
- Before changing UI, read DESIGN.md and inspect the matching Light and Dark
  frames through the Figma MCP server (sections such as "2 · Inbox" or
  "iPhone · Mail" on the macOS, iPadOS and iOS pages).
- Use DESIGN.md's tokens and SF Symbols; reuse the shared tokens in
  `packages/mail-core/src/theme.ts` and add only the tokens the task needs.
- Where a frame differs from a product requirement or feature guide (including
  the stale mockups DESIGN.md lists), the requirement wins: implement it and
  list the difference in the PR.
- A request for visual design, or a look the frames do not show yet, starts in
  Figma and waits for the user's [design approval](docs/agents/implementation-review.md#design-approval).

## Verify

Follow the [testing policy](docs/agents/testing.md) and
[validation commands](README.md#validation): prefer integration and E2E tests,
and add a test only for a named behavior or failure risk. For native builds and
interaction tests, follow the [native validation guide](docs/agents/native-validation.md).
The clients target iOS, iPadOS and macOS 27. Report a check you could not run
as deferred.

## Deliver

- Update the documentation the change affects.
- Add a changeset for runtime behavior or exported API/type changes.
- Track work in [GitHub Issues](docs/agents/issue-tracker.md) with the
  [triage labels](docs/agents/issue-tracker.md#triage-labels).
- An implementation request authorizes commit, push, PR delivery and monitoring
  within its explicit limits. Follow the
  [repository policy](docs/agents/pull-request-babysitting.md) for PR delivery and babysitting.
