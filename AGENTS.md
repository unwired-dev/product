# AGENTS.md

## Purpose

This repository contains the Apple-first private email client and Convex backend. Use this file as the working guide for coding agents. Keep changes focused, respect a dirty working tree, and do not revert user changes unless explicitly asked.

## Repo Overview

- Package manager: `pnpm`
- Task runner: `turbo`
- TypeScript tooling config source: `https://github.com/rajzik/configs`
- TypeScript package layout: `packages/*`
- Apple app layout: `apps/unwired-mail`
- Backend package: `packages/convex`

## Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## Workflow

1. Inspect nearby implementation, tests, and pattern docs before editing.
2. Prefer existing abstractions and conventions over introducing new ones.
3. For ad hoc runnable code, create a temporary file in `scratchpad/`, run it with `node scratchpad/<file>.ts`, and delete it when done.
   The local runtime is Node 24, which can run TypeScript files directly; use plain `node` for local TypeScript probes instead of `tsx` unless `node` fails.
4. Add a changeset with `pnpm changeset` when the change should appear in package release notes.
5. Run the validation appropriate to the change type.
6. Report which validation commands were run and any commands that could not be run.

## Required Checks

Every code change must have lint, format, and test coverage before handoff unless a required tool or platform dependency is unavailable. Run the smallest meaningful checks for the touched area first, then broaden when changing shared config, workspace wiring, or cross-package behavior.

## Documentation Requirements

Every change must consider documentation. Update the relevant docs in the same change when behavior, setup, commands, architecture, environment variables, public interfaces, or agent workflow expectations change.

Use these documentation locations:

- `README.md` for developer setup, common commands, and high-level project navigation.
- `CONTEXT.md` for product language, domain terms, and resolved ambiguity.
- `.patterns/` for reusable code documentation and implementation patterns.
- `.changeset/` for release-intent notes and Changesets configuration.
- `docs/adr/` for durable architecture decisions and privacy-boundary decisions.
- `docs/bootstrap-review.md` for initial bootstrap shape until implementation supersedes it.
- `AGENTS.md` for agent workflow, validation, CI, and handoff requirements.

If a code change does not require a documentation update, say that explicitly in the final handoff.

### TypeScript

- Lint: `pnpm lint`
- Format: `pnpm format`
- Test: `pnpm test`
- Codebase intelligence: `pnpm fallow` ([Fallow](https://docs.fallow.tools/))

TypeScript linting must use Oxlint with `@rajzik/oxlint-config`.
TypeScript formatting must use Oxfmt with `@rajzik/oxfmt-config`.
TypeScript config must extend `@rajzik/tsconfig`.

### Apple App

The iOS, iPadOS, and macOS app must provide formatter, linter, and test commands.

- Format: `swift-format lint --recursive --strict apps/unwired-mail/unwired-mail apps/unwired-mail/unwired-mailTests`
- Lint: `swiftlint lint apps/unwired-mail`
- Test: `xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16'`

If Apple tooling is unavailable in the current environment, state that clearly in the final handoff.

## CI Expectations

The repository must have CI pipelines under `.github/workflows/`.

Pull request and default-branch CI must run the same checks agents are expected to run locally:

- `pnpm install --frozen-lockfile`
- `pnpm lint`
- `pnpm format`
- `pnpm turbo run check-types`
- `pnpm test`
- `pnpm fallow`
- `swift-format lint --recursive --strict apps/unwired-mail/unwired-mail apps/unwired-mail/unwired-mailTests`
- `swiftlint lint apps/unwired-mail`
- `xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16'` once the Xcode project exists.

Keep TypeScript and Apple validation in separate CI jobs so failures identify the affected toolchain clearly. Any temporarily non-blocking bootstrap job must include a comment naming why it is non-blocking and what issue will make it required.

## Completion Checklist

Before finishing:

1. Confirm only intended files changed.
2. Run relevant lint, format, typecheck, and test commands for the touched area.
3. Update docs when commands, config, public behavior, or setup steps change.
4. Summarize what was verified and what was not run.

## Changesets

Create a changeset in `.changeset/` for runtime behavior changes or exported type/API changes:

```md
---
'package-name': patch/minor/major
---

A description of the change.
```

Tests-only changes, internal refactors, docs-only changes, and JSDoc-only maintenance may skip changesets by maintainer decision.
