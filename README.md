# Unwired Mail

Private email client and Convex backend.

The repository contains the SwiftUI and Mac Catalyst prototype and an Expo mock
Inbox for iPhone and iPad. The approved replacement uses a separate native React
Native Mac host, with Gmail first and Android, Windows, IMAP/SMTP, and Microsoft
365 in later slices. Google and Apple Product Sign-In replace Apple-only login.

Start with [the accepted rewrite](docs/adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
and [the 78-ticket coverage index](docs/qualification/expo-rewrite-ticket-coverage.md).
The [Expo bootstrap](docs/expo-client.md) uses Effect v4 and native split-view
navigation. Full [platform qualification](docs/qualification/expo-react-native-client.md)
remains required before release.

## Current checkout

- `apps/mobile`: Expo mock Inbox in the root pnpm workspace.
- `packages/mail-core`: framework-independent mock mailbox and theme tokens.
- `apps/unwired-mail`: SwiftUI client for iPhone, iPad, and Mac Catalyst.
- `packages/contracts`: shared API contracts and fixtures.
- `packages/convex`: Convex backend.
- `packages/mail-test-harness`: current local mail test tooling.

One root workspace and lockfile use a shared catalog and a named `mobile` catalog under
[ADR 0064](docs/adr/0064-isolate-mobile-and-macos-native-dependencies.md).

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
The commands below start the existing backend.

If `.env.local` does not exist, copy `.env.example` to it. Start Convex with:

```sh
mise exec -- pnpm --filter @private-email/convex dev
```

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
existing harness; the replacement's isolated Mock Mail Sessions follow
[ADR 0060](docs/adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).

CI covers the Expo app, shared core/contracts, and retained Convex backend. Legacy
Swift build, performance, Core Mail Loop and provider-qualification jobs are disabled
by maintainer decision; their test sources and local commands remain available.

## Working on the project

- [Documentation index and historical status](docs/README.md)
- [Agent guide](AGENTS.md)
- [Product terminology](CONTEXT.md)
- [GitHub issue workflow](docs/agents/issue-tracker.md)
- [Automated reviews and PR babysitting](docs/agents/pull-request-babysitting.md)

Record runtime or exported API changes with `mise exec -- pnpm changeset`.
Prepare package versions with `mise exec -- pnpm version-packages`. Package
publishing is not wired because the current workspace packages are private.
