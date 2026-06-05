# Apple client and Convex backend bootstrap review

Issue: https://github.com/unwired-dev/product/issues/1

Status: approved for initial implementation.

This review approves the first project bootstrap shape for the Apple-first private email client and Convex backend. The goal of the bootstrap is to prove that a native Apple client can talk to the backend while preserving the privacy boundary already described in the ADRs.

## Approved workspace structure

Use a small monorepo with explicit ownership boundaries:

```text
.
├── apps/
│   └── unwired-mail/
│       ├── unwired-mail.xcodeproj
│       ├── unwired-mail/
│       │   ├── App/
│       │   ├── Features/
│       │   │   └── Smoke/
│       │   ├── Models/
│       │   ├── Services/
│       │   └── Resources/
│       └── unwired-mailTests/
├── packages/
│   └── convex/
│       ├── convex/
│       │   ├── _generated/
│       │   ├── health.ts
│       │   └── schema.ts
│       ├── package.json
│       └── tsconfig.json
├── docs/
│   └── adr/
├── .github/
│   └── workflows/
│       └── ci.yml
├── AGENTS.md
├── package.json
├── pnpm-lock.yaml
├── pnpm-workspace.yaml
├── turbo.json
└── README.md
```

Approved client shape:

- `apps/unwired-mail` contains the iOS, iPadOS, and macOS SwiftUI application.
- SwiftUI owns the initial UI surface.
- SwiftData is available for local persistence, but the smoke path should not require persisted mailbox or user organization models.
- Backend access lives behind a small service boundary in `Services/`, so future sign-in, encrypted sync, provider push, and mailbox sync code do not leak into views.
- The first feature slice is `Features/Smoke`, which shows backend connectivity only.

Approved backend shape:

- `packages/convex` contains the Convex backend package.
- `packages/convex/convex` contains Convex functions and schema.
- TypeScript is the backend language.
- pnpm is the JavaScript package manager.
- Turborepo owns TypeScript package task orchestration and caching.
- TypeScript tooling must use the shared configs from `https://github.com/rajzik/configs`:
  - `@rajzik/oxlint-config` for Oxlint.
  - `@rajzik/oxfmt-config` for Oxfmt.
  - `@rajzik/tsconfig` for TypeScript.
- Effect is approved for backend workflows that need explicit dependency, error, or async composition. The health smoke path can stay simple until Effect adds real clarity.
- Convex may hold operational account data, encrypted sync blobs, device routing records, and minimal push metadata in later slices.
- Convex must not hold backend-readable mailbox content, provider tokens, category names, category assignments, classification inputs, message bodies, or notification rules.
- Root `package.json` should only delegate package work through `turbo run`; package-specific scripts belong in the relevant package.

Approved agent and quality-gate shape:

- `AGENTS.md` is required at the repository root before implementation starts.
- `AGENTS.md` must document the required validation commands for every change:
  - `pnpm lint` for TypeScript linting through Oxlint.
  - `pnpm format` for TypeScript formatting through Oxfmt.
  - `pnpm test` for workspace tests.
  - `xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16'` for the Apple app once the project exists.
- `AGENTS.md` must state that agents should run the smallest meaningful checks for the change scope, but lint, format, and test coverage are required before handing off code changes unless a tool or platform dependency is unavailable.
- `AGENTS.md` must require documentation updates whenever behavior, setup, commands, architecture, environment variables, public interfaces, or agent workflow expectations change.
- The TypeScript workspace must expose package scripts for `lint`, `format`, `check-types`, and `test`, with root scripts delegating through `turbo run`.
- The Apple app must have formatter, linter, and test commands as part of the bootstrap. Use Swift-format-compatible formatting, SwiftLint-compatible linting, and XCTest through `xcodebuild test` unless implementation discovers a stronger repo-local convention.

Approved CI pipeline shape:

- `.github/workflows/ci.yml` is required as part of the bootstrap.
- CI must run on pull requests and pushes to the default branch.
- CI must install dependencies with `pnpm install --frozen-lockfile`.
- CI must run TypeScript validation:
  - `pnpm lint`
  - `pnpm format`
  - `pnpm turbo run check-types`
  - `pnpm test`
- CI must run Apple app validation once the Xcode project exists:
  - Swift-format-compatible formatting check.
  - SwiftLint-compatible lint check.
  - `xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16'`
- CI should keep TypeScript and Apple validation as separate jobs so package/toolchain failures are easy to diagnose.
- If a CI job is temporarily allowed to be non-blocking during bootstrap, the workflow file must make that explicit with a comment and the issue that will make it blocking.

## Local development commands

Expected bootstrap commands:

```sh
pnpm install
pnpm --filter @private-email/convex convex dev
open apps/unwired-mail/unwired-mail.xcodeproj
xcodebuild -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Optional test commands once targets exist:

```sh
pnpm test
pnpm lint
pnpm format
pnpm turbo run check-types
pnpm --filter @private-email/convex convex dev --once
xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 16'
```

The first implementation should keep these commands in `README.md` as soon as the files exist.

## Required environment variables

Backend development:

- `CONVEX_DEPLOYMENT`: Convex deployment selected by `pnpm --filter @private-email/convex convex dev`.

Apple development:

- `CONVEX_URL`: Convex site or client URL used by debug builds to call backend functions.

The Apple app should read `CONVEX_URL` from an untracked local Xcode configuration file or scheme environment during development. Do not commit developer-specific deployment URLs or secrets.

Not required for the smoke path:

- Mail provider OAuth client IDs or secrets.
- Provider refresh tokens or access tokens.
- Apple Sign in with Apple configuration.
- APNs push keys.
- User account recovery secrets.
- Any category, mailbox, message, or notification-rule data.

## First smoke path

Implement a backend health endpoint and a native UI check:

1. Convex exposes a public `health` action in `packages/convex/convex/health.ts`.
2. The endpoint accepts no arguments.
3. The action returns only operational bootstrap data, including current server time from the action handler:

```ts
{
  service: "private-email-api",
  status: "ok",
  bootstrapVersion: 1,
  serverTime: Date.now()
}
```

4. The SwiftUI app has a smoke view that calls the health endpoint through the backend service boundary.
5. The smoke view displays connected, loading, and failed states.
6. The smoke view does not request mailbox permissions, start provider OAuth, create a product account, send device identifiers, persist message data, or create categories.

This proves client-to-backend connectivity without touching mailbox access, provider tokens, encrypted user organization data, push routing data, or classification input. Keep `serverTime` out of Convex queries because cached/reactive query results can become stale or churn the query cache when they depend on `Date.now()`; if this endpoint is ever changed to a query, remove `serverTime` from the response.

## Review decision

Approved for implementation with these constraints:

- Keep the initial repo layout minimal and avoid adding mailbox/provider abstractions before the health path works.
- Keep the smoke endpoint unauthenticated only while it exposes no user, device, mailbox, or sensitive operational data.
- Add authentication and deployment hardening before any endpoint accepts user-specific data.
- Keep all product organization data either local-only or encrypted before it leaves a trusted device.
