# Unwired Mail

Private email client and Convex backend.

The repository contains the SwiftUI and Mac Catalyst prototype and an Expo mock
Inbox for iPhone and iPad, plus a native React Native Mac mock Inbox. The approved
replacement ships with Gmail first and Android, Windows, IMAP/SMTP, and Microsoft
365 in later slices. Google and Apple Product Sign-In replace Apple-only login.

Start with [the documentation index](docs/README.md)
for requirements, setup and validation.
The review agent reads [the architecture index](docs/architecture/README.md)
under the [implementation and review workflow](docs/agents/implementation-review.md).
Follow [Expo setup](docs/expo-client.md) for mobile coding conventions and commands.
Full platform qualification remains required before release; the reviewer tracks
its evidence through the architecture index.

## Current checkout

- `apps/mobile`: Expo Apple and Google onboarding and selected mock Inbox in the root workspace.
- `apps/macos`: AppKit React Native macOS Apple and Google onboarding and mock Inbox windows.
- `packages/mail-core`: framework-independent mock mailbox and theme tokens.
- `apps/unwired-mail`: SwiftUI client for iPhone, iPad, and Mac Catalyst.
- `packages/contracts`: shared API contracts and fixtures.
- `packages/convex`: Convex backend.
- `packages/mail-test-harness`: current local mail test tooling.

One root workspace and lockfile use a shared catalog and named `mobile` and `macos` catalogs under
[Expo workspace setup](docs/expo-client.md#dependencies-and-coding-rules).

## Local development

Use mise, Node 24, and the exact pnpm version in `package.json`, currently 11.5.2.
Expo builds need the Xcode toolchain and simulator runtime documented in
[Expo setup](docs/expo-client.md#install-and-run).

```sh
mise trust .mise.toml
mise install
mise exec -- pnpm install
```

For the replacement app, follow [Expo installation and launch](docs/expo-client.md#install-and-run).
For Mac, follow [native Mac setup](docs/macos-client.md).

Turborepo runs the app and backend tasks from the repository root:

| Command                        | Runs                                                      |
| ------------------------------ | --------------------------------------------------------- |
| `pnpm ios`                     | Builds and launches the iOS development client with Metro |
| `pnpm dev:ios`                 | Metro for an installed iOS development client             |
| `pnpm macos`                   | Metro while it builds and opens the Debug Mac app         |
| `pnpm dev:macos`               | Metro for an existing Debug Mac app                       |
| `pnpm native:build:macos`      | The Release Mac app; pass `Debug` or `Testing` instead    |
| `pnpm dev:convex`              | Convex development against the root `.env.local`          |
| `pnpm build`                   | Both production JavaScript bundles                        |
| `pnpm verify:bundle`           | Both bundles, then their bundle checks                    |
| `pnpm native:generate`         | Both generated native projects                            |
| `pnpm test:native:ios <app>`   | The iOS native runner for a built `.app`                  |
| `pnpm test:native:macos <app>` | The Mac native runner for a built `.app`                  |

Arguments after the script name reach the package command, for example
`pnpm ios --device`. The iOS and Mac Metro servers both use port 8081, so run one
at a time. Development servers use Turborepo's terminal UI and need an interactive
terminal; non-interactive shells run the package scripts directly.

If `.env.local` does not exist, copy `.env.example` to it before starting Convex.

Follow [the Swift prototype setup](docs/swift-client.md) for app environment
settings, signing, provider configuration, and current behavior. Keep credentials
and developer-specific deployment values out of source control.

## Validation

```sh
mise exec -- pnpm lint
mise exec -- pnpm format
mise exec -- pnpm turbo run check-types
mise exec -- pnpm test
mise exec -- pnpm test:tooling
mise exec -- pnpm fallow
```

Use [the testing policy](docs/agents/testing.md) to select meaningful checks and
[the native validation guide](docs/agents/native-validation.md) for resource
ownership during native checks. The [mail test environment](docs/mail-test-environment.md) documents the
existing harness; the replacement's [isolated Mock Mail Sessions](docs/mock-mail-sessions.md) keep deterministic mocked journeys distinct from real integration evidence.

CI covers both replacement hosts, shared core/contracts, and the retained Convex backend. Legacy
Swift build, performance, Core Mail Loop and provider-qualification jobs are disabled
by maintainer decision; their test sources and local commands remain available.

## Working on the project

- [Documentation index and historical status](docs/README.md)
- [Agent guide](AGENTS.md)
- [Implementation and review workflow](docs/agents/implementation-review.md)
- [Product terminology](GLOSSARY.md)
- [GitHub issue workflow](docs/agents/issue-tracker.md)
- [Automated reviews and PR babysitting](docs/agents/pull-request-babysitting.md)

Record runtime or exported API changes with `mise exec -- pnpm changeset`.
Prepare package versions with `mise exec -- pnpm version-packages`. Package
publishing is not wired because the current workspace packages are private.
