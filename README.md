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

Gmail provider connection also requires `GMAIL_OAUTH_CLIENT_ID` so the device can validate pasted refresh tokens with Google before storing them locally. Use an Apple app environment value for local development, and set the app target's `GMAIL_OAUTH_CLIENT_ID` build setting for release-style builds so the non-secret client id is bundled in Info.plist. Keep any OAuth client secrets out of the app.

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

The first app screen is the Product Account path. It lets a user sign in with Apple, create or resume a Product Account, register the current trusted device with the backend using only operational account data, and still verify backend health from the authenticated screen.

### Sign in with Apple (local development)

Sign in with Apple requires a signed build with the capability enabled. Error 1000 (`AuthorizationError unknown`) almost always means signing or entitlements are missing.

1. Open `apps/unwired-mail/unwired-mail.xcodeproj` in Xcode.
2. Select the `unwired-mail` target → **Signing & Capabilities**.
3. Choose your **Development Team** (Apple Developer Program membership required).
4. Confirm **Sign in with Apple** appears under Capabilities (the repo includes `unwired-mail.entitlements`).
5. In [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list), enable **Sign in with Apple** for App ID `dev.unwired.mail`, or change the bundle identifier to one you control and set matching `APPLE_BUNDLE_ID` in the Convex deployment environment (`packages/convex/.env.local` for local dev).
6. Clean build folder and run again on **My Mac (Mac Catalyst)** or an iOS simulator.

CI keeps code signing disabled for simulator tests; only local runs that exercise Apple sign-in need the steps above.

### Product Account verification

Manual verification against a running Convex deployment:

1. Start the backend with `pnpm dev` and set `CONVEX_URL` for the Apple app.
2. Launch the app, sign in with Apple, and confirm the authenticated screen shows product account and trusted device identifiers.
3. Sign out, sign in again with the same Apple ID, and confirm the product account identifier stays the same while device registration resumes cleanly.
4. Automated coverage lives in `packages/convex/test/productAccount.test.ts` and the Apple unit tests under `apps/unwired-mail/unwired-mailTests/`.

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
zsh scripts/check-apple-lint.zsh
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
