# Agent guide

## Start here

The maintained clients are Expo in `apps/mobile` and React Native macOS in
`apps/macos`; the SwiftUI and Mac Catalyst prototype remains in `apps/unwired-mail`.
Use the [documentation index](docs/README.md) for feature scope and evidence.
Set up the mise-managed toolchain and the nearest `package.json`
package-manager version with the [setup instructions](README.md#local-development),
then follow [Expo setup](docs/expo-client.md) for the root workspace, its single
lockfile and scoped native catalogs, and [Mac setup](docs/macos-client.md) for the
desktop host.

Read the issue, [documentation index](docs/README.md), relevant
[domain index](GLOSSARY.md), its relevant topic glossary, and the nearest nested
`AGENTS.md` before editing. For user-visible work, also read the [design](#design).

## Implementation and review

Follow the [implementation and review workflow](docs/agents/implementation-review.md)
for every implementation, including later implementation fixes.

- Before ChatGPT/Codex delegates work, follow the workflow's
  [subagent model policy](docs/agents/implementation-review.md#subagent-model-policy).
- The implementer never reads repository architecture documentation, including
  `docs/architecture/`, ADRs, `.patterns/`, `.opencodereview/rule.json`, `.opencodereview/rules/`, and the reviewer-only sources listed
  in the workflow. This role boundary takes precedence over architecture-reading
  instructions in other repository guides or skills.
- Search the repository as the implementer with `scripts/implementer-grep`
  (`git grep` arguments, pathspecs after `--`), which always excludes those
  sources. Do not use `grep -r`, `rg` or bare `git grep` across the checkout.
- Invoke `ponytail` before implementing. For React, React Native or Expo work,
  use [native component and skill selection](docs/agents/native-components.md).
- The workflow owns [review depth](docs/agents/implementation-review.md#review-depth),
  handoffs, [review limits](docs/agents/implementation-review.md#four-round-safeguard)
  and [decision authority](docs/agents/implementation-review.md#decision-panel).
  Read the applicable branches rather than reproducing their procedures here.

## Coding principles

- State material assumptions, acceptance criteria and the checks that prove them.
  Choose reversible details within those criteria under the workflow's decision policy.
- Make the smallest complete change. Match existing style, preserve unrelated
  working-tree changes and remove only code made unused by this task.
- For UI, native component selection takes precedence over generic reuse advice.
  Record a concrete API gap for any custom standard control or interaction.

## Design

[DESIGN.md](DESIGN.md) and the
[Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T)
Figma file define how the maintained clients look and behave. Implement every
user-visible change according to them.

- For any task involving design, load and follow both the `impeccable` and
  `apple-design` skills before design planning, implementation or review.
  Resolve both through the session skill catalogue. If either is missing, follow
  the [Work](#work) skill discovery, vetting and installation workflow using
  `rajzik/agent-config@impeccable` or `rajzik/agent-config@apple-design` from
  [agent-config](https://github.com/rajzik/agent-config).
- Before changing UI, read DESIGN.md and inspect the matching frames through the
  Figma MCP server: the macOS, iPadOS and iOS pages are organized into numbered
  or platform-prefixed sections (for example "2 · Inbox" or "iPhone · Mail"), each
  with Light and Dark frames.
- Use DESIGN.md's color, typography, spacing and radius tokens, and SF Symbols.
  Reuse matching shared tokens in `packages/mail-core/src/theme.ts`; add or
  update only the tokens needed for the task. Do not invent undocumented values
  or icon styles.
- Follow the frames for layout, copy, states and platform behavior on Mac, iPad
  and iPhone. Product requirements and feature guides govern behavior, controls
  and defaults where a frame differs, including the stale mockups DESIGN.md
  lists; apply them directly and list the difference in the PR so the design
  can follow. Resolve conflicts or missing states through
  [decision authority](docs/agents/implementation-review.md#decision-panel).
- Design Figma first. When a request asks for visual design or redesign, or
  changes how a client looks beyond what the frames already show, update the
  Figma frames before writing code, then ask the user to review them. Implement
  only after the user approves, following the workflow's
  [design approval](docs/agents/implementation-review.md#design-approval).
- User-visible changes also pass the
  [design review](docs/agents/implementation-review.md#design-review).

## Work

- When changing product terminology or `GLOSSARY.md`, follow the
  [domain documentation policy](docs/agents/domain.md).
- Packages are deep modules: read [packages/README.md](packages/README.md) before
  adding a package, an entry point or a cross-package import.
- Put temporary probes in `scratchpad/`, run TypeScript with plain Node 24,
  and remove task-owned probes afterward.
- Use the installed skills that match the task and their applicable references.
  When a needed capability is missing, use `find-skills`, vet the candidate with
  `skill-inspector` or by reading its instructions and scripts, then install it
  using the project toolchain. If `find-skills` is absent, install it with
  `mise exec -- pnpm dlx skills add vercel-labs/skills@find-skills`.
  Use `task-observer` for requested workflow
  improvement or a repeated workflow problem that warrants an observation.

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
- An implementation request authorizes commit, push, PR delivery and monitoring
  within its explicit limits. Follow the canonical
  [repository policy](docs/agents/pull-request-babysitting.md) for PR delivery and babysitting.
- Report verification results and unavailable checks accurately.

## Effect

Before writing or reviewing TypeScript, read the
[Effect conventions](docs/agents/effect.md) and, for service definitions,
[Define Effect services](docs/agents/effect-services.md). Before writing Effect
code, read `node_modules/effect/AGENTS.md` **completely** and follow its links;
search `node_modules/effect/src` for APIs the guides do not cover.

<!-- graft:start -->

## Graft code navigation

For code discovery, use `graft ask "<question>" --source`, `graft skeleton <file>`
or `graft callers <symbol>` when the local graph has relevant context. Verify
returned spans against the task checkout before editing; ranked hits are not an
exhaustive caller or occurrence list. Refresh the graph after substantial code
changes with `graft build`.

For documentation tasks, start with `docs/README.md`. When graph context is absent,
irrelevant or incompatible with the reading boundary, use `scripts/implementer-grep`
and scoped source reads. Use that wrapper for exhaustive implementer searches;
the graph does not override reviewer-only source restrictions.

<!-- graft:end -->

<!-- BEGIN:turborepo-agent-rules -->

# This is NOT the Turborepo you know

Turborepo configuration, task behavior, and CLI commands can vary between installed versions and may differ from your training data. Resolve the `turbo` package from this file's directory or relevant workspace; in monorepos, it may not be visible from the repository root. For example, run `node -p "require.resolve('turbo/package.json')"` from a workspace that depends on `turbo`.

Read `docs/README.md` inside that installed package first, then read the relevant pages from its `docs/` directory before changing Turborepo configuration or commands. Heed deprecation notices. These bundled docs match the installed package version and are available without network access.

This block is written and re-added by `turbo` before repository-scoped commands when an AI agent is detected. In the Turborepo source repository, its template is defined in `crates/turborepo-cli/src/cli/agent_guidance.rs`. Removing the managed block while updates are enabled means a later qualifying invocation will add it again. Set `"agentGuidance": false` in the root `turbo.json` or `turbo.jsonc` to opt out; this does not remove an existing block. Keep the block committed with your work to avoid an uncommitted change on the next agent invocation.
<!-- END:turborepo-agent-rules -->
