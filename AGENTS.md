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
- Invoke the `ponytail` and `unlazy` skills before implementing, and follow both
  throughout the implementation.
- After implementing and running the relevant checks, spawn a separate review
  agent with explicit `model: "gpt-6.1-sol"`, `reasoning_effort: "high"`, and
  `fork_turns: "none"`, regardless of the implementer's model or reasoning effort.
  Use the workflow's Open Code Review delegation step and resolved repository
  rules for architecture checking inside that review agent.
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
