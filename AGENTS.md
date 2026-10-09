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
  `docs/architecture/`, ADRs, `.patterns/`, `.opencodereview/rule.json`, `.opencodereview/rules/`, and the reviewer-only sources listed
  in the workflow. This role boundary takes precedence over architecture-reading
  instructions in other repository guides or skills.
- Invoke the `ponytail` skill before implementing, and follow it and the
  [coding principles](#coding-principles) throughout the implementation.
- For React, React Native or Expo work, also invoke `vercel-react-native-skills`
  and `vercel-composition-patterns` before editing, and follow both.
- After implementing and running the relevant checks, spawn a separate review
  agent with explicit `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, and
  `fork_turns: "none"`, regardless of the implementer's model or reasoning effort.
  Use the workflow's Open Code Review delegation step and resolved repository
  rules for architecture checking inside that review agent.
  Pause writes until its final report; later implementer edits need another review.
- Never pause implementation for a user decision. Send it to the workflow's
  [decision panel](docs/agents/implementation-review.md#decision-panel)
  (`claude-fable-5-1`, `gpt-6.1-sol`, `gpt-6-astra`); the majority wins.

## Coding principles

### Think before coding

State assumptions, surface confusion, and name tradeoffs before implementing.

- State your assumptions explicitly.
- When the request has several interpretations, list them rather than picking one
  silently.
- When a simpler approach exists, say so and push back where warranted.
- When something is unclear or uncertain, name what is confusing and send the
  question to the [decision panel](#implementation-and-review) instead of guessing.

### Simplicity first

Write the minimum code that solves the problem, with nothing speculative.

- Build only the requested features.
- Inline single-use code instead of abstracting it.
- Add flexibility or configuration only when requested.
- Handle only errors that can actually occur.
- When 200 lines could be 50, rewrite them.

Ask: would a senior engineer call this overcomplicated? If so, simplify.

### Surgical changes

Touch only what the request requires, and clean up only your own mess.

- Leave adjacent code, comments, and formatting as they are; refactor only what
  is broken.
- Match the existing style, even where you would write it differently.
- Mention unrelated dead code instead of deleting it.
- Remove imports, variables, and functions that your changes made unused.
- Preserve unrelated working-tree changes.

Every changed line should trace directly to the request.

### Goal-driven execution

Define success criteria, then loop until they are verified.

Turn each task into a verifiable goal:

- "Add validation" → write tests for invalid inputs, then make them pass.
- "Fix the bug" → write a test that reproduces it, then make it pass.
- "Refactor X" → ensure tests pass before and after.

For multi-step tasks, state a brief plan:

```text
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong criteria let you loop independently; weak ones ("make it work") need
constant clarification.

## Work

- When changing product terminology or `GLOSSARY.md`, follow the
  [domain documentation policy](docs/agents/domain.md).
- Put temporary probes in `scratchpad/`, run TypeScript with plain Node 24,
  and remove task-owned probes afterward.
- Invoke `task-observer` for task-oriented work and consult relevant open skill
  observations. Resolve skills through the session catalogue.
- Invoke the [`find-skills`](https://agenticskills.io/skills/find-skills) skill
  at the start of each development job and whenever a new domain comes up
  (testing, animation, a library, CI). Pick an installed skill from the session
  catalogue first. When none fits, search the ecosystem with
  `npx skills find <query>`, vet the best candidate with `skill-inspector` (or,
  when that skill is unavailable, by reading its `SKILL.md` and bundled scripts),
  then install it with `npx skills add <package>` and follow it. If `find-skills`
  itself is missing, install it with `npx skills add vercel-labs/skills@find-skills`.

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

<!-- graft:start -->

## Graft — repo context graph

This repo is indexed in `graft/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `graft map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `graft ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `graft grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `graft skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `graft callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `graft/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `graft ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `graft build` (deterministic,
no API key, $0).
<!-- graft:end -->

<!-- BEGIN:turborepo-agent-rules -->

# This is NOT the Turborepo you know

Turborepo configuration, task behavior, and CLI commands can vary between installed versions and may differ from your training data. Resolve the `turbo` package from this file's directory or relevant workspace; in monorepos, it may not be visible from the repository root. For example, run `node -p "require.resolve('turbo/package.json')"` from a workspace that depends on `turbo`.

Read `docs/README.md` inside that installed package first, then read the relevant pages from its `docs/` directory before changing Turborepo configuration or commands. Heed deprecation notices. These bundled docs match the installed package version and are available without network access.

This block is written and re-added by `turbo` before repository-scoped commands when an AI agent is detected. In the Turborepo source repository, its template is defined in `crates/turborepo-cli/src/cli/agent_guidance.rs`. Removing the managed block while updates are enabled means a later qualifying invocation will add it again. Set `"agentGuidance": false` in the root `turbo.json` or `turbo.jsonc` to opt out; this does not remove an existing block. Keep the block committed with your work to avoid an uncommitted change on the next agent invocation.
<!-- END:turborepo-agent-rules -->
