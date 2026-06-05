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

## Required Checks

Every code change must have lint, format, and test coverage before handoff unless a required tool or platform dependency is unavailable. Run the smallest meaningful checks for the touched area first, then broaden when changing shared config, workspace wiring, or cross-package behavior.

## Documentation Requirements

Every change must consider documentation. Update the relevant docs in the same change when behavior, setup, commands, architecture, environment variables, public interfaces, or agent workflow expectations change.

Use these documentation locations:

- `README.md` for developer setup, common commands, and high-level project navigation.
- `CONTEXT.md` for product language, domain terms, and resolved ambiguity.
- `docs/adr/` for durable architecture decisions and privacy-boundary decisions.
- `docs/bootstrap-review.md` for initial bootstrap shape until implementation supersedes it.
- `AGENTS.md` for agent workflow, validation, CI, and handoff requirements.

If a code change does not require a documentation update, say that explicitly in the final handoff.

### TypeScript

- Lint: `pnpm lint`
- Format: `pnpm format`
- Typecheck: `pnpm turbo run check-types`
- Test: `pnpm test`

TypeScript linting must use Oxlint with `@rajzik/oxlint-config`.
TypeScript formatting must use Oxfmt with `@rajzik/oxfmt-config`.
TypeScript config must extend `@rajzik/tsconfig`.

### Apple App

The iOS, iPadOS, and macOS app must provide formatter, linter, and test commands.

- Format: use a Swift-format-compatible command once configured.
- Lint: use a SwiftLint-compatible command once configured.
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
- Apple formatter check once configured.
- Apple linter check once configured.
- `xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16'` once the Xcode project exists.

Keep TypeScript and Apple validation in separate CI jobs so failures identify the affected toolchain clearly. Any temporarily non-blocking bootstrap job must include a comment naming why it is non-blocking and what issue will make it required.

## Completion Checklist

Before finishing:

1. Confirm only intended files changed.
2. Run relevant lint, format, typecheck, and test commands for the touched area.
3. Update docs when commands, config, public behavior, or setup steps change.
4. Summarize what was verified and what was not run.
