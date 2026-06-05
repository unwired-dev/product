# product

Apple-first private email client and Convex backend.

## Requirements

- mise
- pnpm 11
- Node.js 24
- Xcode 16 with the iPhone 17 simulator runtime
- `swift-format` and SwiftLint for Apple formatting and linting

## Workspace

- `apps/unwired-mail`: SwiftUI iOS, iPadOS, and Mac Catalyst client.
- `packages/contracts`: Shared cross-boundary API contracts and JSON fixtures.
- `packages/convex`: Convex backend functions.

## Local Development

Install the pinned JavaScript toolchain:

```sh
mise install
```

Install TypeScript workspace dependencies:

```sh
pnpm install
```

Run the Convex backend development environment:

```sh
cp .env.example packages/convex/.env.local
pnpm dev
```

`convex dev` fills in `CONVEX_DEPLOYMENT` after you log in. Set `CONVEX_URL` for the Apple app to the deployment URL shown by `convex dev`. Use an untracked `apps/unwired-mail/.env.local` file, a local Xcode scheme environment variable, or another untracked local configuration. Do not commit developer-specific Convex URLs or secrets.

Open and run the Apple app:

```sh
open apps/unwired-mail/unwired-mail.xcodeproj
```

Build for iOS simulator:

```sh
xcodebuild -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Build the documented macOS equivalent target through Mac Catalyst:

```sh
xcodebuild -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=macOS,variant=Mac Catalyst' build
```

On Apple Silicon machines, use the explicit arm64 destination if Xcode tries to build both Catalyst slices:

```sh
xcodebuild -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' build
```

The first app screen is the smoke path. It calls the public Convex `health:health` action through the service boundary and displays loading, connected, or failed backend state.

## Validation

TypeScript:

```sh
pnpm lint
pnpm format
pnpm turbo run check-types
pnpm test
pnpm fallow
```

[Fallow](https://docs.fallow.tools/) runs dead-code, duplication, and complexity analysis on the TypeScript workspace.

Apple:

```sh
swift-format lint --recursive --strict apps/unwired-mail/unwired-mail apps/unwired-mail/unwired-mailTests
swiftlint lint apps/unwired-mail
xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Release Notes

Use Changesets to record release-intent notes for package changes:

```sh
pnpm changeset
```

Prepare package version bumps and changelogs from committed changesets:

```sh
pnpm version-packages
```

Publishing is not wired yet because the current workspace packages are private.

## Project planning

- [Product context](CONTEXT.md)
- [Bootstrap review](docs/bootstrap-review.md)
- [Architecture decisions](docs/adr/)
- [Agent instructions](AGENTS.md)
