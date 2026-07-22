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
cp .env.example .env.local
pnpm dev
```

`convex dev` fills in `CONVEX_DEPLOYMENT` after you log in. Set `CONVEX_URL` for the Apple app to the deployment URL shown by `convex dev`. Debug builds read `CONVEX_URL`, `GMAIL_OAUTH_CLIENT_ID`, and `GMAIL_PUBSUB_TOPIC` from the repository-root `.env.local`; backend-only values are ignored. An untracked `apps/unwired-mail/.env.local` file or local Xcode scheme environment variables can override those defaults. Do not commit developer-specific Convex URLs or secrets.

Gmail provider connection requires an **iOS OAuth client ID** from the Google Cloud project, configured for the app's bundle identifier. Enable the Gmail API, configure the OAuth consent screen with the `openid`, `email`, and `gmail.modify` scopes, then set the client ID as `GMAIL_OAUTH_CLIENT_ID`. Also set the app target's `GMAIL_OAUTH_CALLBACK_SCHEME` build setting to its reversed client ID (for example, `com.googleusercontent.apps.1234567890-abc`); iOS must register that scheme before Google can return to the app. Debug builds may read the client ID from the repository-root or app-specific `.env.local`, but the callback scheme remains an Xcode build setting. Release-style builds should set both values in the app target so the non-secret client ID and callback registration are bundled in Info.plist. **Sign in with Google** opens the system authentication window, uses PKCE, and reuses the browser's Google session when available. A Product Account can connect multiple Gmail mailboxes. Their non-secret definitions and the user-selected Default Sending Connection synchronize through end-to-end encrypted Product Sync, while every trusted device must authorize each mailbox independently. **Remove Device Authorization** clears only this device's credentials, caches, and push state; **Remove Mailbox Connection Everywhere** publishes a durable removal tombstone after local cleanup succeeds, fences provider access on other devices, and never deletes provider mail. Keep OAuth client secrets out of the app.

### Mailbox Connection boundary

The Apple client routes provider connection, metadata synchronization, message reading, provider search, push registration, sending, and Provider Mail Actions through a provider-neutral Mailbox Connection adapter. The shared boundary carries distinct typed identities for Product Account, Mailbox Connection, Stable Provider Mailbox Identity, Thread, and Stable Provider Message Identity. It also declares synchronization, reading, search, push, sending, reply, forward, historical-categorization, and Provider Mail Action capabilities explicitly, so presentation code exposes only operations supported by that connection. A synchronized connection without device-local credentials remains visible with authorization-required state and no mail-access or sending capabilities. The Default Sending Connection remains selected when unavailable locally; the client requires authorization or explicit user selection instead of silently substituting another sender. Gmail remains the only implemented adapter and continues using its native API; later provider adapters can supply different capabilities without changing the Gmail implementation or reducing every provider to Gmail behavior.

### Generic mail server setup

The authenticated account screen can prepare a device-local IMAP/SMTP or legacy POP3/SMTP connection. Enter an address to apply the bundled reviewed iCloud Mail or Fastmail settings, or enter hostnames, ports, and transport modes manually. Every discovered value remains editable and is shown before connection. The bundled entries follow [Apple's iCloud Mail server settings](https://support.apple.com/en-us/102525) and [Fastmail's IMAP, POP, and SMTP settings](https://www.fastmail.help/hc/en-us/articles/1500000279921); unknown and custom domains use manual setup rather than guessed hostnames.

Setup accepts OAuth access tokens through XOAUTH2, app-specific passwords, or passwords. Reviewed provider entries choose their preferred method; unknown manual setups default to password because the app cannot infer OAuth support from an unknown provider, while users with an existing OAuth token can select OAuth explicitly. IMAP `SPECIAL-USE` roles are applied when exactly one provider mailbox declares the role; only missing or ambiguous roles require explicit mapping, and a saved setup can be reopened to change those mappings later. POP3 instead uses the product-owned local roles defined for its reduced legacy contract. The app verifies both incoming and SMTP authentication only after implicit TLS or a successful STARTTLS upgrade with a system-trusted server identity and a TLS 1.2 minimum. Only then does it store the connection definition and credential in the current device's ThisDeviceOnly Keychain and synchronize the reviewed address, username, endpoints, transport modes, authorization method, and role mappings through end-to-end encrypted Product Sync. Provider credentials never enter Product Sync or Convex. Signing out or switching Product Accounts clears these generic-mail authorizations together with Gmail authorization.

Issue #64 establishes setup and authorization only. Reading and complete-history synchronization through IMAP are tracked by issue #65; actions, drafts, SMTP delivery, and freshness are tracked by issue #66.

### Gmail push relay

Gmail push keeps provider OAuth tokens on trusted devices. A device calls Gmail `users.watch` with its local credential, refreshes a short-lived Google OpenID Connect ID token, and submits that identity proof with the returned history ID. Convex authenticates the trusted device before fetching Google's cached signing keys, validates the ID token signature locally, and then checks its issuer, audience, expiry, verified canonical email, and stable Google subject against the connected mailbox. The ID token is held only long enough to verify the watch: it is excluded from the device's Keychain encoding and is never persisted or logged by Convex. Only an ownership-verified pending proof can be completed by matching or later Minimal Push Metadata from the authenticated Pub/Sub endpoint. Convex then sends APNs wakeups to the verified Product Account devices, and the receiving device fetches mailbox changes with its own Gmail token. The APNs payload contains only `provider: gmail`, the Gmail history ID, and an opaque connection route ID; it contains no message content, account identifiers, categories, classifications, notification rules, or provider credentials. Signing out or switching Product Accounts unregisters the device's APNs route, asks Gmail to stop the active watch only when no other registered device route depends on that mailbox, and clears cached push-account metadata. If authenticated unregistration fails, Convex clears the route and its Gmail push proof after 30 days without a device registration heartbeat; the client never retains an obsolete Product Account identity token for cleanup retries.

Configure the Google and Apple infrastructure before enabling the path:

1. Create a Pub/Sub topic in the same Google Cloud project as the Gmail OAuth client, and grant `gmail-api-push@system.gserviceaccount.com` permission to publish to it.
2. Set `GMAIL_PUBSUB_TOPIC` for the Apple target to the fully qualified topic name, such as `projects/example/topics/gmail-push`. Local debug builds may set it in `apps/unwired-mail/.env.local`; release builds should set the target's `GMAIL_PUBSUB_TOPIC` build setting.
3. Create a Pub/Sub push subscription whose endpoint is `https://<deployment>.convex.site/gmail/push?token=<GMAIL_PUSH_VERIFICATION_TOKEN>`. Set the same high-entropy `GMAIL_PUSH_VERIFICATION_TOKEN` in the Convex deployment.
4. Set `GMAIL_OAUTH_CLIENT_ID` in the Convex deployment to the same iOS OAuth client ID used by the app so mailbox ownership proofs have a fixed audience.
5. Enable Push Notifications and the Remote notifications background mode for App ID `dev.unwired.mail` (or the selected bundle ID), and configure `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, and `APNS_TOPIC` in the Convex deployment. `APNS_PRIVATE_KEY` is the Apple `.p8` contents; when an environment manager requires one line, encode line breaks as `\n`.

The client renews a Gmail watch when less than one day remains, matching Gmail's daily-renewal recommendation. Each accepted background wake refreshes only the newest Gmail inbox page and advances the local history watermark; foreground/manual sync performs full pagination and reconciliation. Before persisting newly fetched inbox metadata, the client journals notification eligibility by Stable Provider Message Identity and Gmail history boundary. A retry can therefore finish category-aware delivery after an interrupted wake, while overlapping wakes still share message-level delivery claims and durable completed-delivery receipts. Eligibility is ignored once the route watermark covers its history boundary, so completed work cannot notify again. Background APNs delivery is best effort, so foreground/manual inbox sync remains available when the system delays or drops a wakeup.

### Gmail search

The Apple client searches locally retained metadata by sender, recipient, subject, received date, Gmail state, and Message Category. Users can explicitly run the same query as Gmail full-text search when they need provider-side body matching; those results are labelled separately and are not added to the local metadata store. The client does not create a backend-readable mail index or a durable plaintext body index. See [ADR 0006](docs/adr/0006-local-metadata-search-provider-full-text-search.md).

### Category-aware notifications

Signed-in users can enable Notification Rules for System Categories and their Custom Category. The client encrypts the selected category identifiers with Product Sync key material before syncing them; the backend stores only opaque encrypted user data. Authenticated rule loads and saves also refresh an account-scoped Keychain cache containing only that encrypted Product Sync payload. A Gmail background wake can decrypt the cache when its stored Product Sync identity token has expired, then schedule a visible local notification only after the trusted device fetches the new message, categorizes it locally, and matches its category against those rules. A successful authenticated load of an empty rule set clears stale cached rules. Rules are empty by default. A separate device-only Generic Notification Fallback is also off by default; when the user enables it, failed, incomplete, or out-of-time category processing may instead schedule a content-free new-mail notification. The fallback does not sync and does not expose Notification Rules, categories, or message content to the backend. See [ADR 0008](docs/adr/0008-device-evaluated-category-aware-notifications.md).

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

1. Set your Apple team in the untracked `apps/unwired-mail/unwired-mail/LocalSigning.xcconfig` file: `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. (The local development setup creates this file for you.)
2. Open `apps/unwired-mail/unwired-mail.xcodeproj` in Xcode and confirm **Sign in with Apple** appears under Capabilities (the repo includes `unwired-mail.entitlements`).
3. In [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list), enable **Sign in with Apple** for App ID `dev.unwired.mail`, or change the bundle identifier to one you control and set matching `APPLE_BUNDLE_ID` in the Convex deployment environment (`.env.local` at the repository root for local dev).
4. Clean build folder and run again on **My Mac (Mac Catalyst)** or an iOS simulator.

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
