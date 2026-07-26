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

For Linux CI parity against local changes, install and authenticate the
[Blacksmith CLI](https://docs.blacksmith.sh/blacksmith-testbox/overview), then
warm the repository's TypeScript Testbox from the repository root:

```sh
curl -fsSL https://get.blacksmith.sh | sh
blacksmith auth login
blacksmith testbox warmup blacksmith-testbox.yml --job typescript
```

Reuse the returned Testbox ID to sync local changes and run checks in the warm
CI environment, then stop it when finished:

```sh
blacksmith testbox run --id <ID> "pnpm install --frozen-lockfile && pnpm lint && pnpm format && pnpm turbo run check-types && pnpm test && pnpm fallow"
blacksmith testbox stop --id <ID>
```

Run `blacksmith testbox` from the repository root because it mirrors the current
working tree with deletion enabled. Testboxes provide the Linux TypeScript
environment only; Apple lint and Xcode tests still run locally or in macOS CI.

Run the Convex backend development environment:

```sh
cp .env.example .env.local
pnpm dev
```

`convex dev` fills in `CONVEX_DEPLOYMENT` after you log in. Set `CONVEX_URL` for the Apple app to the deployment URL shown by `convex dev`. Debug builds read `CONVEX_URL`, `GMAIL_OAUTH_CLIENT_ID`, `GMAIL_PUBSUB_TOPIC`, and `MICROSOFT_GRAPH_CLIENT_ID` from the repository-root `.env.local`; backend-only values are ignored. An untracked `apps/unwired-mail/.env.local` file or local Xcode scheme environment variables can override those defaults. Do not commit developer-specific Convex URLs or secrets.

Gmail provider connection requires an **iOS OAuth client ID** from the Google Cloud project, configured for the app's bundle identifier. Enable the Gmail API, configure the OAuth consent screen with the `openid`, `email`, and `gmail.modify` scopes, then set the client ID as `GMAIL_OAUTH_CLIENT_ID`. Also set the app target's `GMAIL_OAUTH_CALLBACK_SCHEME` build setting to its reversed client ID (for example, `com.googleusercontent.apps.1234567890-abc`); iOS must register that scheme before Google can return to the app. Debug builds may read the client ID from the repository-root or app-specific `.env.local`, but the callback scheme remains an Xcode build setting. Release-style builds should set both values in the app target so the non-secret client ID and callback registration are bundled in Info.plist. **Sign in with Google** opens the system authentication window, uses PKCE, and reuses the browser's Google session when available. A Product Account can connect multiple Gmail mailboxes. Their non-secret definitions and the user-selected Default Sending Connection synchronize through end-to-end encrypted Product Sync, while every trusted device must authorize each mailbox independently. **Remove Device Authorization** clears only this device's credentials, caches, and push state; **Remove Mailbox Connection Everywhere** publishes a durable removal tombstone after local cleanup succeeds, fences provider access on other devices, and never deletes provider mail. Keep OAuth client secrets out of the app.

The adaptive mail shell is the only production Gmail reading and action surface; Account Settings manages connections without embedding a second inbox. Credential, cache, push, and UI state must always be scoped by Product Account and Mailbox Connection identity. See [ADR 0018](docs/adr/0018-local-mail-performance-budget.md) for the Gmail-first Release performance check.

Microsoft 365 connection requires a public-client application registration that allows personal Microsoft accounts and organizational Exchange Online accounts. Register the exact redirect URI `MICROSOFT_GRAPH_CALLBACK_SCHEME:/oauthredirect`, then set its application (client) ID as `MICROSOFT_GRAPH_CLIENT_ID` and the registered URI scheme as the app target's `MICROSOFT_GRAPH_CALLBACK_SCHEME` build setting. Debug builds may read the client ID from `.env.local`, but the callback scheme must be a build setting so it is registered in Info.plist. The client requests delegated `User.Read`, `Mail.Read`, and `offline_access` access with PKCE. Tokens stay in this device's Keychain; only the non-secret Mailbox Connection definition synchronizes through encrypted Product Sync. The adapter imports the newest 50 messages first, resumes folder-by-folder metadata backfill from durable Microsoft Graph delta links, preserves native folder roles and conversation identifiers, and uses the shared encrypted body cache. Microsoft connections are read-only in this release.

### Mailbox Connection boundary

The Apple client routes provider connection, metadata synchronization, message reading, provider search, push registration, sending, and Provider Mail Actions through a provider-neutral Mailbox Connection adapter. The shared boundary carries distinct typed identities for Product Account, Mailbox Connection, Stable Provider Mailbox Identity, Thread, and Stable Provider Message Identity. It also declares synchronization, reading, search, push, sending, reply, forward, historical-categorization, and Provider Mail Action capabilities explicitly, so presentation code exposes only operations supported by that connection. A synchronized connection without device-local credentials remains visible with authorization-required state and no mail-access or sending capabilities. The Default Sending Connection remains selected when unavailable locally; the client requires authorization or explicit user selection instead of silently substituting another sender. Gmail continues using its native API, Microsoft 365 uses Microsoft Graph, and generic providers use the same boundary through an IMAP read-and-synchronize adapter without reducing provider-native behavior to protocol-common behavior.

Every composer displays its sending Mailbox Connection. New messages start with the synchronized Default Sending Connection, while replies and forwards start with their source Thread's connection and require an explicit choice to change it; unavailable, unauthorized, and receive-only connections cannot send. The product-owned Outbox encrypts pending message content on device, resumes after restart, and retries offline or transient failures with bounded exponential backoff for at most 10 attempts or seven days. Each edit creates a new immutable delivery attempt, and a stable RFC Message-ID lets Gmail Sent reconciliation resolve ambiguous handoffs without duplicate delivery. Permanent failures stop for editing, cancellation, or explicit retry; an outcome the provider cannot reconcile must be marked Sent or Not Sent before it can leave the unknown state. Signing out removes the account's local Outbox.

Gmail read-state, archive, move, delete, restore, spam, and star changes are local-first. The Apple client persists each action before attempting Gmail, projects the ordered actions over durable provider metadata immediately, and resumes the per-connection queue after restart or reconnection. Unified Mailboxes allow multi-select across Mailbox Connections and expose only the Provider Mail Actions supported by every selected connection. A bulk action becomes one ordered batch per connection, shows connection-level progress and failures, and preserves successful batches when another connection fails. Transient failures use bounded exponential retry with jitter; a permanent rejection restores provider-derived state and continues later intent, while authorization or exhausted retries remain visible for user action. Queues for separate Mailbox Connections progress independently, and Provider Mail Actions never modify product-owned Pins.

Gmail Durable Message Metadata is stored per Product Account and Mailbox Connection in SwiftData. A new connection publishes Initial Mailbox Availability after the newest 50 provider-visible messages are persisted, then continues Historical Metadata Backfill from a durable page checkpoint while cached mailbox views remain usable. Backfill pauses in Low Power Mode and resumes from the saved page after cancellation, restart, or a later sync. Full scans include Spam and Trash, retain provider labels for non-Inbox mail, keep the Inbox projection label-scoped, and retire unseen records only when the complete scan finishes, so an interrupted scan cannot mistake unfinished pagination for provider deletion. Existing file-backed metadata migrates into SwiftData on first load; message bodies remain outside this metadata store.

After initial availability and again after historical backfill, the Apple client prefetches authenticated-encrypted bodies for at most the newest 500 Inbox and Sent messages from the previous 30 days per Mailbox Connection. Planned Thread-wide body prefetch will also make every non-Spam, non-Trash body in a Pinned Thread eligible regardless of age, subject to the cache-fitting protected-set rules; until then, pinning affects only the pinned message's prefetch eligibility. Drafts, Spam, Trash, attachments, and older unpinned bodies remain outside this prefetch path. The device-wide message-body cache is capped at 500 MB; explicit message opens remain available offline from the cache and update eviction recency without storing plaintext bodies.

The planned signed-in Apple app uses an adaptive mail shell. macOS and wide iPad layouts will show the Mailbox Connection sidebar, selected mailbox Thread list, and conversation reader together. The permanent Unified Mailboxes will be Inbox, Pins, Drafts, Sent, Archive, All Mail, Spam, and Trash; Outbox will remain hidden until a pending, retrying, or failed delivery exists. A Pin belongs to the whole Thread independently of provider stars or flags. The optimistic local change updates Unified Pins immediately and synchronizes as an opaque end-to-end encrypted, connection-scoped Product Sync record across trusted devices. Gmail label state is projected into canonical roles without mutating provider labels, All Mail excludes Spam and Trash, and unread and item counts come from locally observed metadata across connections. Provider-specific labels use their Gmail names, remain beneath their source Mailbox Connection even when empty, and select only that connection's matching messages. Unified views interleave locally observed Threads from every authorized Gmail Mailbox Connection by latest-message time, visibly label each row with its source connection, and preserve the selected Thread while other connections insert or reorder rows. Selecting a connection returns to its connection-scoped Inbox. Narrow iPad and iPhone layouts collapse the same mailbox and Thread selections into hierarchical navigation. A conversation will show every locally observed message newest to oldest, keep the newest message expanded at the top, and let users expand older messages below it; reply and forward drafts remain bound to the source Mailbox Connection. Product Account, provider setup, categories, notification rules, search, and other diagnostic tools remain available from Account Settings.

The planned Mail View bar will filter the selected mailbox's Thread list without changing mailbox membership. Important and All will be fixed in the first two positions, followed by up to three user-configurable one-Category views; the initial configurable views will be Orders, Newsletters & Promotions, and Flights. The Important view will initially include People, Invites, Orders, and Flights. One end-to-end encrypted configuration will apply across all mailboxes, while the selected mailbox and Mail View remain transient navigation state: every new application session will start in Unified Inbox with Important selected. Synchronization progress will appear in a bottom-anchored, non-blocking overlay above the Mail View bar so list rows do not move.

New message will be a separate action from the planned Mail View bar. Planned new-message, reply, reply-all, and forward composers will open as one partial-height composer by default and can expand to full screen; a synchronized global preference may make full screen the default. The composer will present the semantic rich-text message body first, followed by Subject and recipient fields, and continuously autosave one encrypted Draft with independently encrypted attachments and inline-image assets. Markdown shortcuts, formatting controls, context actions, autocomplete recipients, paste and drop, and attachment picking will all operate on that same Draft representation.

### Generic mail server setup

The authenticated account screen can prepare a device-local IMAP/SMTP or legacy POP3/SMTP connection. Enter an address to apply the bundled reviewed iCloud Mail or Fastmail settings, or enter hostnames, ports, and transport modes manually. Every discovered value remains editable and is shown before connection. The bundled entries follow [Apple's iCloud Mail server settings](https://support.apple.com/en-us/102525) and [Fastmail's IMAP, POP, and SMTP settings](https://www.fastmail.help/hc/en-us/articles/1500000279921); unknown and custom domains use manual setup rather than guessed hostnames.

Setup accepts OAuth access tokens through XOAUTH2, app-specific passwords, or passwords. Reviewed provider entries choose their preferred method; unknown manual setups default to password because the app cannot infer OAuth support from an unknown provider, while users with an existing OAuth token can select OAuth explicitly. IMAP `SPECIAL-USE` roles are applied when exactly one provider mailbox declares the role; only missing or ambiguous roles require explicit mapping, and a saved setup can be reopened to change those mappings later. POP3 instead uses the product-owned local roles defined for its reduced legacy contract. The app verifies both incoming and SMTP authentication only after implicit TLS or a successful STARTTLS upgrade with a system-trusted server identity and a TLS 1.2 minimum. Only then does it store the connection definition and credential in the current device's ThisDeviceOnly Keychain and synchronize the reviewed address, username, endpoints, transport modes, authorization method, and role mappings through end-to-end encrypted Product Sync. Provider credentials never enter Product Sync or Convex. Signing out or switching Product Accounts clears these generic-mail authorizations together with Gmail authorization.

Authorized IMAP connections now read mailbox metadata through TLS or STARTTLS, expose the newest 50 messages per mailbox first, and resume complete-history backfill from connection-scoped SwiftData checkpoints. Synchronization honors unambiguous `SPECIAL-USE` roles and saved mappings, keys messages by mailbox plus UIDVALIDITY and UID, reconciles provider changes and expunges only after a complete scan, and groups conversations only from RFC Message-ID linkage. Opened and recent message bodies use the shared bounded encrypted cache; the client selects and downloads only a displayable text MIME part, leaving attachments on demand. Provider actions, drafts, SMTP delivery, and active/background IMAP freshness remain tracked by issue #66.

### Gmail push relay

Gmail push keeps provider OAuth tokens on trusted devices. A device calls Gmail `users.watch` with its local credential, refreshes a short-lived Google OpenID Connect ID token, and submits that identity proof with the returned history ID. Convex authenticates the trusted device before fetching Google's cached signing keys, validates the ID token signature locally, and then checks its issuer, audience, expiry, verified canonical email, and stable Google subject against the connected mailbox. The ID token is held only long enough to verify the watch: it is excluded from the device's Keychain encoding and is never persisted or logged by Convex. Only an ownership-verified pending proof can be completed by matching or later Minimal Push Metadata from the authenticated Pub/Sub endpoint. Convex then sends APNs wakeups to the verified Product Account devices, and the receiving device fetches mailbox changes with its own Gmail token. The APNs payload contains only `provider: gmail`, the Gmail history ID, and an opaque connection route ID; it contains no message content, account identifiers, categories, classifications, notification rules, or provider credentials. Signing out or switching Product Accounts unregisters the device's APNs route, asks Gmail to stop the active watch only when no other registered device route depends on that mailbox, and clears cached push-account metadata. If authenticated unregistration fails, Convex clears the route and its Gmail push proof after 30 days without a device registration heartbeat; the client never retains an obsolete Product Account identity token for cleanup retries.

Configure the Google and Apple infrastructure before enabling the path:

1. Create a Pub/Sub topic in the same Google Cloud project as the Gmail OAuth client, and grant `gmail-api-push@system.gserviceaccount.com` permission to publish to it.
2. Set `GMAIL_PUBSUB_TOPIC` for the Apple target to the fully qualified topic name, such as `projects/example/topics/gmail-push`. Local debug builds may set it in `apps/unwired-mail/.env.local`; release builds should set the target's `GMAIL_PUBSUB_TOPIC` build setting.
3. Create a Pub/Sub push subscription whose endpoint is `https://<deployment>.convex.site/gmail/push?token=<GMAIL_PUSH_VERIFICATION_TOKEN>`. Set the same high-entropy `GMAIL_PUSH_VERIFICATION_TOKEN` in the Convex deployment.
4. Set `GMAIL_OAUTH_CLIENT_ID` in the Convex deployment to the same iOS OAuth client ID used by the app so mailbox ownership proofs have a fixed audience.
5. Set high-entropy, backend-only `GMAIL_ROUTING_KEY` and `GMAIL_IDENTITY_BINDING_KEY` values plus the positive integer `GMAIL_ROUTING_KEY_VERSION` in the Convex deployment. Convex derives versioned routing digests from transient, verified Gmail addresses and stable identity-binding digests from Google account identities; none of the source values or keys are stored or returned. Keep the identity-binding key stable when rotating routing keys. To rotate routing, configure `GMAIL_ROUTING_PREVIOUS_KEY` and `GMAIL_ROUTING_PREVIOUS_KEY_VERSION` with the former values until every active route has renewed on the new version, then remove both previous-key variables.
6. Enable Push Notifications and the Remote notifications background mode for App ID `dev.unwired.mail` (or the selected bundle ID), and configure `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, and `APNS_TOPIC` in the Convex deployment. `APNS_PRIVATE_KEY` is the Apple `.p8` contents; when an environment manager requires one line, encode line breaks as `\n`.

The client renews a Gmail watch when less than one day remains, matching Gmail's daily-renewal recommendation. Each accepted background wake refreshes only the routed Gmail connection's newest inbox page and advances its local history watermark. Every authorized Gmail connection also performs full reconciliation at launch and foreground activation, with a non-overlapping five-minute fallback poll while the app remains active. Cached mailbox data loads before launch reconciliation, and a global manual refresh is available in the mailbox sidebar. Each connection shows authorization-required, syncing, backfill-pending, offline, error, and durable last-success state without hiding cached mail; successful background reconciliation notifies active mailbox views to reload their locally observed metadata. Before persisting newly fetched inbox metadata, the client journals notification eligibility by Stable Provider Message Identity and Gmail history boundary. A retry can therefore finish category-aware delivery after an interrupted wake, while overlapping wakes still share message-level delivery claims and durable completed-delivery receipts. Eligibility is ignored once the route watermark covers its history boundary, so completed work cannot notify again. Background APNs delivery is best effort, so the next wake, foreground activation, fallback poll, or manual refresh reconciles signals the system delays or drops.

### Gmail search

The Apple client searches locally retained metadata by sender, recipient, subject, received date, Gmail state, and Message Category. Users can explicitly run the same query as Gmail full-text search when they need provider-side body matching; those results are labelled separately and are not added to the local metadata store. The client does not create a backend-readable mail index or a durable plaintext body index. See [ADR 0006](docs/adr/0006-local-metadata-search-provider-full-text-search.md).

### Category-aware notifications

Today's Apple client syncs selected category identifiers for Notification Rules and offers a device-local Generic Notification Fallback. The global notification switch and per-connection policy below are planned Settings-redesign work, not shipped controls. When that redesign is implemented, the client will encrypt the global notification switch, selected category identifiers, and per-connection notification policy with Product Sync key material before syncing them; the backend will store only opaque encrypted user data. Authenticated rule loads and saves will also refresh an account-scoped Keychain cache containing only that encrypted Product Sync payload. Successful authenticated categorization reads will separately refresh an encrypted, account-scoped, device-only snapshot of the Custom Categories and exact-sender Future Learning Signals, including explicit absence. Future Learning Signal entries expire after 24 hours; the categorization snapshot is replaced by the next authenticated refresh, including explicit absence, and the cache is cleared on sign-out or Product Account change. A Gmail background wake will use the rules cache when Product Sync loading fails, including when its stored identity token has expired, and will use the categorization cache only after a remote categorization read fails; it can then schedule a visible local notification only after the trusted device fetches the new message, categorizes it locally, confirms the global switch and connection policy permit delivery, and matches any of its categories against those rules. Missing, stale, corrupt, or sender-mismatched categorization context will leave the message uncategorized; foreground categorization remains network-authoritative. A successful authenticated load of an empty rule set clears stale cached rules. After local encryption succeeds, a save attempt invalidates its prior rule cache before contacting Product Sync, so a network or authentication failure cannot leave changed or removed rules available to background processing. Cache fallback remains unavailable until a later authenticated load, successful save, or conflict response also succeeds in writing the authoritative payload to Keychain. Rules are empty by default. The separate device-only Generic Notification Fallback is also off by default; when the user enables it, failed, incomplete, or out-of-time category processing may instead schedule a content-free new-mail notification. The fallback does not sync and does not expose Notification Rules, categories, or message content to the backend. See [ADR 0008](docs/adr/0008-device-evaluated-category-aware-notifications.md).

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

The first app screen is the Product Account path. It lets a user sign in with Apple, create or resume a Product Account, and register the current trusted device with the backend using only operational account data. After sign-in, the adaptive mail shell becomes the root experience; the current Account Settings sheet contains diagnostics and raw backend health. The planned Settings redesign moves diagnostics to Advanced when that entry point ships.

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

## Automated code review

[CodeRabbit](https://docs.coderabbit.ai/getting-started/yaml-configuration)
uses the repository-root [`.coderabbit.yaml`](.coderabbit.yaml) together with
the nearest `AGENTS.md` instructions. It automatically reviews non-draft pull
requests to the default branch and incrementally reviews new pushes. Pull
requests from common dependency and automation bots are skipped, as are pull
requests whose title contains `[WIP]` or `[skip review]` or that carry the
`do-not-review` label. Generated Convex client files are excluded from review.

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
