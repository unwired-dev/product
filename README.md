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

`convex dev` fills in `CONVEX_DEPLOYMENT` after you log in. Set `CONVEX_URL` for the Apple app to the deployment URL shown by `convex dev`. When the HTTP-action endpoint cannot be derived from that URL, set `CONVEX_SITE_URL` explicitly. Debug builds running on the development Mac or in Simulator read `CONVEX_URL`, `CONVEX_SITE_URL`, the `EWS_OAUTH_*` settings, `GMAIL_OAUTH_CLIENT_ID`, `GMAIL_PUBSUB_TOPIC`, and `MICROSOFT_GRAPH_CLIENT_ID` from the repository-root `.env.local`; backend-only values are ignored. A physical iOS device cannot read the source-tree file. Provide `CONVEX_URL` and, when needed, `CONVEX_SITE_URL` as Xcode scheme environment variables; `LocalSigning.xcconfig` build settings are not bundled for `BackendEnvironment` to read. Other app build settings needed on a physical device can use the untracked `apps/unwired-mail/unwired-mail/LocalSigning.xcconfig` as documented below. Do not commit developer-specific Convex URLs or secrets.

Gmail provider connection requires an **iOS OAuth client ID** from the Google Cloud project, configured for the app's bundle identifier. Enable the Gmail API, configure the OAuth consent screen with the `openid`, `email`, and `gmail.modify` scopes, then set the client ID as `GMAIL_OAUTH_CLIENT_ID`. Also set `GMAIL_OAUTH_CALLBACK_SCHEME` to its reversed client ID (for example, `com.googleusercontent.apps.1234567890-abc`); iOS must register that scheme before Google can return to the app. For a local physical-device build, add both settings to `apps/unwired-mail/unwired-mail/LocalSigning.xcconfig`. Release-style builds should likewise provide both values through the app target configuration so the non-secret client ID and callback registration are bundled in Info.plist. **Sign in with Google** opens the system authentication window, uses PKCE, and reuses the browser's Google session when available. A Product Account can connect multiple Gmail mailboxes. Their non-secret definitions and the user-selected Default Sending Connection synchronize through end-to-end encrypted Product Sync, while every trusted device must authorize each mailbox independently. A Gmail connection whose device-local token is missing remains visible as authorization-required with no mail or push capabilities, so the user can reconnect it or remove its stale operational route without a provider credential. **Remove Device Authorization** clears only this device's credentials, caches, and push state; **Remove Mailbox Connection Everywhere** publishes a durable removal tombstone after local cleanup succeeds, fences provider access on other devices, and never deletes provider mail. Re-adding the same provider mailbox advances its encrypted authorization generation, so a trusted device that was offline during removal must authorize again instead of reusing its pre-removal credential. Keep OAuth client secrets out of the app.

The adaptive mail shell is the only production Gmail reading and action surface; Account Settings manages connections without embedding a second inbox. Credential, cache, push, and UI state must always be scoped by Product Account and Mailbox Connection identity. See [ADR 0018](docs/adr/0018-local-mail-performance-budget.md) for the Gmail-first Release performance check.

Inside a Product Account, Mail Profiles are encrypted workspace boundaries. Each app window presents exactly one Profile, restores that device-local selection independently, and uses the device-local Startup Profile only for a new window. The Profile switcher shows the synchronized name and curated icon/color identity; Unified Mailboxes, search, message context, and compose sender choices include only connections assigned to that Profile. Provider synchronization and Profile-identified notifications continue for inactive Profiles. Targeted routes use `unwired-mail://mail?profileId=<opaque-profile-id>` and override window restoration without putting a Profile name or mail content in the URL.

Microsoft 365 connection requires a public-client application registration that allows personal Microsoft accounts and organizational Exchange Online accounts. Add the iOS/macOS platform for the app's bundle identifier; Microsoft generates the redirect URI `msauth.<bundle-id>://auth`. Set the registration's application (client) ID as `MICROSOFT_GRAPH_CLIENT_ID` and the generated `msauth.<bundle-id>` URI scheme as the app target's `MICROSOFT_GRAPH_CALLBACK_SCHEME` build setting. Debug builds may read the client ID from `.env.local`, but the callback scheme must be a build setting so it is registered in Info.plist. The client requests delegated `User.Read`, `Mail.ReadWrite`, `Mail.Send`, and `offline_access` access with PKCE; connections authorized with the earlier read-only scopes must be authorized again once. Tokens stay in this device's Keychain; only the non-secret Mailbox Connection definition synchronizes through encrypted Product Sync. The adapter imports the newest 50 messages first, resumes folder-by-folder metadata backfill from durable Microsoft Graph delta links, and maintains a separate recent Inbox delta cursor until that backfill completes so moved or deleted cached messages disappear promptly. It preserves native folder roles and conversation identifiers and uses the shared encrypted body cache. Microsoft connections support read state, archive, move, delete, restore, spam, compose, reply, reply-all, forward, Outbox reconciliation, and sending through Microsoft Graph.

Microsoft Graph change notifications use the same APNs device registration as Gmail. The app uses `CONVEX_SITE_URL` when configured and otherwise derives the Convex HTTP endpoint from `CONVEX_URL`, registers an opaque route and client-state digest, and keeps Microsoft access and refresh tokens on-device. The backend validates and coalesces provider signals, then sends only the provider name and opaque route ID through APNs; the app performs delta synchronization after the wake-up or the next foreground refresh. Foreground synchronization, received wakes, and opportunistic iOS background fetch renew Graph subscriptions during their final 24 hours so a quiet mailbox does not depend on receiving a notification before expiry.

On-premises Exchange 2013 SP1, Exchange 2016, and Exchange 2019 mailboxes connect through an organization-hosted HTTPS EWS endpoint using TLS 1.2 or newer. Account Settings rejects HTTP and known Exchange Online or Microsoft 365 endpoints, which must use Microsoft Graph. Passwords and app-specific passwords stay in this device's ThisDeviceOnly Keychain. A deployment that exposes OAuth 2.0 authorization-code flow with PKCE and issues refresh tokens for its EWS scope can also configure `EWS_OAUTH_AUTHORIZATION_ENDPOINT`, `EWS_OAUTH_TOKEN_ENDPOINT`, `EWS_OAUTH_CLIENT_ID`, `EWS_OAUTH_CALLBACK_SCHEME`, and `EWS_OAUTH_SCOPE`. The authorization and token endpoints must use HTTPS; `EWS_OAUTH_CALLBACK_SCHEME` is build-time only and must be registered with both the provider and the app. Simulator and macOS debug builds may read the other non-secret values from `.env.local`; physical-device and release builds must provide them as Apple target build settings, for example through the untracked `apps/unwired-mail/unwired-mail/LocalSigning.xcconfig`. Never embed an OAuth client secret: Unwired is a public PKCE client. OAuth access and refresh credentials and their expiry remain only in the device's ThisDeviceOnly Keychain. Unwired refreshes an expiring access token before EWS provider access, persists provider-rotated refresh credentials, and presents explicit reauthorization after the provider rejects a refresh grant. Existing manually supplied EWS OAuth access tokens cannot be refreshed and therefore become authorization-required. The reviewed endpoint, username, address, authorization method, and verified server version synchronize only inside encrypted Product Sync; OAuth provider endpoints and credentials do not synchronize. EWS relies on the system TLS trust evaluation and never accepts an invalid server identity. The adapter loads the newest 50 messages per folder before folder-by-folder history backfill, preserves EWS folder roles, stable search keys, and conversation identifiers, refreshes recent folder pages, and uses the shared encrypted body cache, pending-action queue, product-owned Pins, and Outbox. When another client moves an older message and invalidates its EWS item identity, actions and uncached body loads use a result-capped server-side stable-key search across physical mail folders, persist the recovered item, change, and parent-folder identities, and retry once. EWS supports read state, archive, move, delete and restore, spam state, flags, message reading, local metadata search, compose, reply, forward, synchronized Drafts and Sent folders, and retry isolation per Mailbox Connection; it does not advertise provider full-text search, historical categorization, or provider push.

### Mailbox Connection boundary

The Apple client routes provider connection, metadata synchronization, message reading, provider search, push registration, sending, and Provider Mail Actions through a provider-neutral Mailbox Connection adapter. The shared boundary carries distinct typed identities for Product Account, Mailbox Connection, Stable Provider Mailbox Identity, Thread, and Stable Provider Message Identity. It also declares synchronization, reading, search, push, sending, reply, reply-all, forward, historical-categorization, and Provider Mail Action capabilities explicitly, so presentation code exposes only operations supported by that connection. A synchronized connection without device-local credentials remains visible with authorization-required state and no mail-access or sending capabilities. The Default Sending Connection remains selected when unavailable locally; the client requires authorization or explicit user selection instead of silently substituting another sender. Gmail continues using its native API, Microsoft 365 uses Microsoft Graph, and generic providers use the same boundary through an IMAP read-and-synchronize adapter without reducing provider-native behavior to protocol-common behavior.

Every composer displays its sending Mailbox Connection. New messages start with the synchronized Default Sending Connection, while replies and forwards start with their source Thread's connection and require an explicit choice to change it; unavailable, unauthorized, and receive-only connections cannot send. Compose Settings synchronizes the Undo Send Window, Compose Presentation Preference, Formatting Toolbar Preference, quoted-reply behavior, and forwarded-attachment behavior through End-to-End Encrypted Product Sync. Undo Send is a cancellable delay before provider handoff; it defaults to 10 seconds and also offers Off, 20 seconds, and 30 seconds. Compose Presentation defaults to Partial, the formatting toolbar is visible by default, reply quotes are included but start collapsed, and forwarded attachments are included by default. Offline Compose preference edits apply locally and merge independently by field; concurrent edits to the same field create a Preference Conflict that preserves both values for explicit resolution. The product-owned Outbox encrypts pending message content on device, persists each Outgoing Delivery Attempt's selected Undo Send deadline across restarts, applies later Undo Send preference changes only to new or edited attempts, and retries offline or transient failures with bounded exponential backoff for at most 10 total attempts, including the initial delivery attempt, or seven days from the first delivery attempt, whichever comes first. Each edit creates a new immutable delivery attempt, and a stable RFC Message-ID lets Gmail and Microsoft Graph Sent reconciliation resolve ambiguous handoffs without duplicate delivery. Permanent failures stop automatic delivery and remain available for editing, cancellation, or explicit retry; an outcome the provider cannot reconcile must be marked Sent or Not Sent before it can leave the unknown state. Sent, cancelled, and superseded attempts are pruned from durable storage. Product Account teardown centrally removes the account's local Outbox before credentials and encryption keys are cleared.

Gmail and Microsoft Graph read-state, archive, move, delete, restore, and spam changes are local-first; Gmail additionally supports star changes. The Apple client persists each action before attempting the provider, projects the ordered actions over durable provider metadata immediately, and resumes the per-connection queue after restart or reconnection. Unified Mailboxes allow multi-select across Mailbox Connections and expose only the Provider Mail Actions supported by every selected connection. A bulk action becomes one ordered batch per connection, shows connection-level progress and failures, and preserves successful batches when another connection fails. Resume and retry errors are associated with the Pending Provider Action IDs matched to the selected messages, so an older failure on the same connection does not make a successful batch appear failed. Transient failures use bounded exponential retry with jitter; a permanent rejection restores provider-derived state and continues later intent, while authorization or exhausted retries remain visible for user action. Queues for separate Mailbox Connections progress independently, and Provider Mail Actions never modify product-owned Pins.

Gmail Durable Message Metadata is stored per Product Account and Mailbox Connection in SwiftData. A new connection publishes Initial Mailbox Availability after the newest 50 provider-visible messages are persisted, then continues Historical Metadata Backfill from a durable page checkpoint while cached mailbox views remain usable. Backfill pauses in Low Power Mode and resumes from the saved page after cancellation, restart, or a later sync. Full scans include Spam and Trash, retain provider labels for non-Inbox mail, keep the Inbox projection label-scoped, and retire unseen records only when the complete scan finishes, so an interrupted scan cannot mistake unfinished pagination for provider deletion. Existing file-backed metadata migrates into SwiftData on first load; message bodies remain outside this metadata store.

For Gmail and Exchange Web Services messages, that metadata-only path also reads `List-ID`, `List-Unsubscribe`, and `List-Unsubscribe-Post` without requesting body bytes. The expanded owning message may show one confirmed Unsubscribe card, preferring RFC one-click HTTPS, then an Outbox-backed `mailto:` request through the receiving Mailbox Connection, with an ordinary HTTPS page as an explicit fallback. One-click requests use the isolated public-destination-only pinned transport with no cookies, credentials, or referrer and no automatic retry after an uncertain dispatch. Not Now suppresses the opaque Mailing List Identity for 14 days; the Inbox Settings toggle synchronizes Unsubscribe enablement and dismissals through end-to-end encrypted Product Sync. Provider request data, mailing-list values, and message content never enter the product backend.

The Apple client detects a structured `text/calendar`, `application/ics`, or `text/x-vcalendar` attachment from Gmail, Standards-Based Mail, Microsoft Graph, or Exchange Web Services metadata without requesting its bytes. Standards-Based Mail retains only the BODYSTRUCTURE selector, MIME type, transfer encoding, and declared size, while Microsoft Graph and EWS request and cancellation messages are detected from their structured provider type. Only an explicit Add to Calendar action retrieves a bounded invitation: attachment-backed invitations pass through the provider's authenticated part or attachment boundary with a 1 MB limit and bounded iCalendar parsing, while structured Graph and EWS meeting messages request only the event fields needed for the on-device Calendar Event Candidate. The Apple client requires review before EventKit creates, updates, or removes an event, requests full Calendar access only from that action, and keeps UID mappings, candidate fields, and Calendar data on device; TypeScript receives none of them. An expanded message displays at most one proactive card, prioritized as Event, Unsubscribe, then Contact; End-to-End Encrypted Product Sync carries only the Feature Suggestion Preference enablement and opaque 14-day dismissals.

After a message body is already loaded, a provider-neutral on-device detector may also offer one prose event when a body within its scan limit contains exactly one unambiguous explicit calendar date—using a month name or ISO `yyyy-mm-dd`—and an explicit time; it never fetches or truncates a body for detection. Prose events always open the native Calendar editor for time-zone, duration, and location review without requiring full Calendar access, and a product-account-wide device-local fingerprint can warn about a possible duplicate but never selects or replaces an invitation-backed event. The detector keeps fingerprints and candidate fields on device and sends none of them to TypeScript.

After initial availability and again after historical backfill, the Apple client prefetches authenticated-encrypted bodies for at most the newest 500 Inbox and Sent messages from the previous 30 days per Mailbox Connection. Planned Thread-wide body prefetch will also make every non-Spam, non-Trash body in a Pinned Thread eligible regardless of age, subject to the cache-fitting protected-set rules; until then, pinning affects only the pinned message's prefetch eligibility. Drafts, Spam, Trash, attachments, embedded images, and older unpinned bodies remain outside this prefetch path. Gmail checks body-free Content-Type metadata first and prefetches only single-part plain-text or HTML messages; multipart messages remain on demand so prefetch cannot receive embedded bytes. The device-wide message-body cache is capped at 500 MB; explicit message opens remain available offline from the cache and update eviction recency without storing plaintext bodies. On an explicit Gmail message open, sanitized `cid:` references may resolve matching MIME image parts into the presentation; only referenced PNG, JPEG, GIF, or WebP data within per-image, count, and total-size bounds is admitted. Inline bytes remain presentation-scoped in memory, are never written to the body cache, and are released with the expanded message view. Forward quoting reads cached text; when no cached body exists, it may fetch only a single-part text message and leaves multipart mail for an explicit open. Retained HTML renders only after on-device SwiftSoup sanitization inside a JavaScript-disabled, non-persistent WebKit boundary. Remote images remain blocked until the current message presentation shows the privacy warning and the user explicitly loads them; the client then admits only bounded HTTPS PNG, JPEG, GIF, or WebP responses fetched without cookies, credentials, or referrer information and injects them as local data. Consent and loaded bytes disappear when that presentation ends, while partial failures leave retained readable content available.

The planned signed-in Apple app uses an adaptive mail shell. macOS and wide iPad layouts will show the Mailbox Connection sidebar, selected mailbox Thread list, and conversation reader together. The permanent Unified Mailboxes will be Inbox, Pins, Drafts, Sent, Archive, All Mail, Spam, and Trash; Outbox will remain hidden until a pending, retrying, or failed delivery exists. A Pin belongs to the whole Thread independently of provider stars or flags. The optimistic local change updates Unified Pins immediately and synchronizes as an opaque end-to-end encrypted, connection-scoped Product Sync record across trusted devices. Gmail label state is projected into canonical roles without mutating provider labels, All Mail excludes Spam and Trash, and unread and item counts come from locally observed metadata across connections. Provider-specific labels use their Gmail names, remain beneath their source Mailbox Connection even when empty, and select only that connection's matching messages. Unified views interleave locally observed Threads from every authorized Gmail Mailbox Connection by latest-message time, visibly label each row with its source connection, and preserve the selected Thread while other connections insert or reorder rows. Selecting a connection returns to its connection-scoped Inbox. Narrow iPad and iPhone layouts collapse the same mailbox and Thread selections into hierarchical navigation. A conversation will show every locally observed message newest to oldest, keep the newest message expanded at the top, and let users expand older messages below it; reply and forward drafts remain bound to the source Mailbox Connection. Product Account, provider setup, categories, notification rules, search, and other diagnostic tools remain available from Account Settings.

The development Settings experience includes a complete Categories destination. It synchronizes a profile-scoped automatic-categorization switch, per-System-Category enablement, multiple Custom Categories, and a learning generation through encrypted Product Sync. Reset Learned Senders advances that generation before clearing cached learning context so in-flight or stale learned results cannot return. Connections that advertise historical categorization can run a cancellable backfill bounded by connection, mailbox, date range, and category target; cancellation preserves assignments already completed.

Mail Profile interruption controls live in the Notifications destination. Quiet synchronizes end-to-end encrypted across Trusted Devices and suppresses visible notifications and proactive suggestions until an absolute end time or explicit resume. Profile Lock stays on the current device, uses Face ID, Touch ID, or the device passcode, conceals Profile UI and Spotlight content, and leaves synchronization, indexing, Outbox, and Scheduled Send work running in the background.

The Mail View bar filters the selected mailbox's Thread list without changing mailbox membership. Important and All are fixed in the first two positions, followed by three user-configurable one-Category views; the initial configurable views are Orders, Newsletters & Promotions, and Flights. The Important view initially includes People, Invites, Orders, and Flights. One end-to-end encrypted configuration applies across all mailboxes in a Mail Profile, while the selected mailbox and Mail View remain transient navigation state: every new application session starts in Unified Inbox with Important selected. Synchronization progress appears in a bottom-anchored, non-blocking overlay above the Mail View bar so list rows do not move.

New message will be a separate action from the Mail View bar. Planned new-message, reply, reply-all, and forward composers will open as one partial-height composer by default and can expand to full screen; a synchronized global preference may make full screen the default. The composer will present the semantic rich-text message body first, followed by Subject and recipient fields, and continuously autosave one encrypted Draft with independently encrypted attachments and inline-image assets. Markdown shortcuts, formatting controls, context actions, autocomplete recipients, paste and drop, and attachment picking will all operate on that same Draft representation.

### Generic mail server setup

The authenticated account screen can prepare a device-local IMAP/SMTP or legacy POP3/SMTP connection. Enter an address to apply the bundled reviewed iCloud Mail or Fastmail settings, or enter hostnames, ports, and transport modes manually. Every discovered value remains editable and is shown before connection. The bundled entries follow [Apple's iCloud Mail server settings](https://support.apple.com/en-us/102525) and [Fastmail's IMAP, POP, and SMTP settings](https://www.fastmail.help/hc/en-us/articles/1500000279921); unknown and custom domains use manual setup rather than guessed hostnames. SwiftMail owns IMAP and SMTP transport, authentication, protocol parsing, and MIME; the product-owned stream verifier remains only for legacy POP3.

Setup accepts OAuth access tokens through XOAUTH2, app-specific passwords, or passwords. Reviewed provider entries choose their preferred method; unknown manual setups default to password because the app cannot infer OAuth support from an unknown provider, while users with an existing OAuth token can select OAuth explicitly. IMAP `SPECIAL-USE` roles are applied when exactly one provider mailbox declares the role; only missing or ambiguous roles require explicit mapping, and a saved setup can be reopened to change those mappings later. POP3 instead uses the product-owned local roles defined for its reduced legacy contract. SwiftMail verifies both IMAP and SMTP authentication only after implicit TLS or a successful STARTTLS upgrade with a system-trusted server identity and a TLS 1.2 minimum. Only then does the app store the connection definition, verified engine capabilities, and credential in the current device's ThisDeviceOnly Keychain and synchronize the reviewed address, username, endpoints, transport modes, authorization method, and role mappings through end-to-end encrypted Product Sync. Provider credentials and protocol decisions never enter Product Sync or Convex. Signing out or switching Product Accounts clears these generic-mail authorizations together with Gmail authorization.

Authorized IMAP connections read mailbox metadata through SwiftMail, expose the newest 50 messages per mailbox first, and resume complete-history backfill from connection-scoped SwiftData checkpoints. Synchronization honors unambiguous `SPECIAL-USE` roles and saved mappings, keys messages by mailbox plus UIDVALIDITY and UID, reconciles provider changes and expunges only after a complete scan, and groups conversations only from RFC Message-ID linkage. Opened and recent message bodies use the shared bounded encrypted cache; SwiftMail selects and downloads only displayable MIME content, leaving attachments on demand.

Read state and star changes are always available. Archive, move, delete, restore, and spam actions are exposed only when verified role mappings and the server's `MOVE` or `UIDPLUS` capabilities make them safe. The shared Pending Provider Action queue survives restart; the UIDPLUS fallback durably records a verified `COPYUID` mapping before targeted source deletion, never uses unrestricted expunge, and preserves Stable Provider Message Identity across UID changes. Advertised `IDLE` keeps the Inbox fresh, reconnects with bounded backoff, and triggers immediate synchronization while the existing polling path remains the fallback.

SwiftMail also renders outgoing MIME, submits SMTP, and appends accepted messages to the mapped Sent mailbox. After SMTP acceptance, the app encrypts the exact MIME bytes in a device-local Sent-copy journal before attempting the append; an append failure retries only the Sent copy and never resubmits SMTP. Ambiguous post-content SMTP outcomes require user reconciliation and are not retried automatically. Product-authored Drafts remain end-to-end encrypted product data as specified by issue #161; messages observed in a provider's Drafts mailbox are read-only provider mail and are not used as product draft storage.

### Gmail push relay

Gmail push keeps provider OAuth tokens on trusted devices. A device calls Gmail `users.watch` with its local credential, refreshes a short-lived Google OpenID Connect ID token, and submits that identity proof with the returned history ID. Convex authenticates the trusted device before fetching Google's cached signing keys, validates the ID token signature locally, and then checks its issuer, audience, expiry, verified canonical email, and stable Google subject against the connected mailbox. The ID token is held only long enough to verify the watch: it is excluded from the device's Keychain encoding and is never persisted or logged by Convex. Only an ownership-verified pending proof can be completed by matching or later Minimal Push Metadata from the authenticated Pub/Sub endpoint. Convex then sends APNs wakeups to the verified Product Account devices, and the receiving device fetches mailbox changes with its own Gmail token. The APNs payload contains only `provider: gmail`, the Gmail history ID, and an opaque connection route ID; it contains no message content, account identifiers, categories, classifications, notification rules, or provider credentials. Signing out or switching Product Accounts unregisters the device's APNs route, asks Gmail to stop the active watch only when no other registered device route depends on that mailbox, and clears cached push-account metadata. If authenticated unregistration fails, Convex clears the route and its Gmail push proof after 30 days without a device registration heartbeat; the client never retains an obsolete Product Account identity token for cleanup retries.

Configure the Google and Apple infrastructure before enabling the path:

1. Create a Pub/Sub topic in the same Google Cloud project as the Gmail OAuth client, and grant `gmail-api-push@system.gserviceaccount.com` permission to publish to it.
2. Set `GMAIL_PUBSUB_TOPIC` for the Apple target to the fully qualified topic name, such as `projects/example/topics/gmail-push`. Simulator and macOS debug builds may read it from the repository-root `.env.local`; local physical-device builds must add it to the untracked `apps/unwired-mail/unwired-mail/LocalSigning.xcconfig`. Release builds should provide it through the app target configuration.
3. Create a Pub/Sub push subscription whose endpoint is `https://<deployment>.convex.site/gmail/push?token=<GMAIL_PUSH_VERIFICATION_TOKEN>`. Set the same high-entropy `GMAIL_PUSH_VERIFICATION_TOKEN` in the Convex deployment.
4. Set `GMAIL_OAUTH_CLIENT_ID` in the Convex deployment to the same iOS OAuth client ID used by the app so mailbox ownership proofs have a fixed audience.
5. Set high-entropy, backend-only `GMAIL_ROUTING_KEY` and `GMAIL_IDENTITY_BINDING_KEY` values plus the positive integer `GMAIL_ROUTING_KEY_VERSION` in the Convex deployment. Convex derives versioned routing digests from transient, verified Gmail addresses and stable identity-binding digests from Google account identities; none of the source values or keys are stored or returned. Keep the identity-binding key stable when rotating routing keys. To rotate routing, configure `GMAIL_ROUTING_PREVIOUS_KEY` and `GMAIL_ROUTING_PREVIOUS_KEY_VERSION` with the former values until every active route has renewed on the new version, then remove both previous-key variables.
6. Enable Push Notifications plus the Background fetch and Remote notifications background modes for App ID `dev.unwired.mail` (or the selected bundle ID), and configure `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, and `APNS_TOPIC` in the Convex deployment. `APNS_PRIVATE_KEY` is the Apple `.p8` contents; when an environment manager requires one line, encode line breaks as `\n`.

The client renews a Gmail watch when less than one day remains, matching Gmail's daily-renewal recommendation. Each accepted background wake refreshes only the routed Gmail connection's newest inbox page and advances its local history watermark. Launch, foreground activation, and the non-overlapping five-minute fallback poll refresh only each authorized Gmail connection's newest Inbox page. An incomplete Historical Metadata Backfill pauses for that foreground refresh, then resumes from its durable page token; an explicit manual refresh remains the full-reconciliation path. Cached mailbox data loads before launch reconciliation, and manual refresh is available globally in the mailbox sidebar and directly in Unified Inbox. Each connection shows authorization-required, syncing, backfill-pending, offline, error, and durable last-success state without hiding cached mail; successful background reconciliation notifies active mailbox views to reload their locally observed metadata. Before persisting newly fetched inbox metadata, the client journals notification eligibility by Stable Provider Message Identity and Gmail history boundary. A retry can therefore finish category-aware delivery after an interrupted wake, while overlapping wakes still share message-level delivery claims and durable completed-delivery receipts. Eligibility is ignored once the route watermark covers its history boundary, so completed work cannot notify again. Background APNs delivery is best effort, so the next wake, foreground activation, fallback poll, or manual refresh reconciles signals the system delays or drops.

### Gmail search

The Apple client searches locally retained metadata by sender, recipient, subject, received date, Gmail state, and Message Category. Users can explicitly run the same query as Gmail full-text search when they need provider-side body matching; those results are labelled separately and are not added to the local metadata store. The client does not create a backend-readable mail index or a durable plaintext body index. See [ADR 0006](docs/adr/0006-local-metadata-search-provider-full-text-search.md).

### Category-aware notifications

The Apple client syncs a global notification switch, selected category identifiers, and optional per-connection policies as encrypted Notification Rules; Convex stores only opaque encrypted user data. Legacy selected-category Notification Rules migrate into the Default Mail Profile with notifications enabled and no Mailbox Connection overrides. Mail Profile-scoped Notification Rules remain independent, while content level, sound, badge, quiet hours, quiet-hour category allowlist, and Generic Notification Fallback stay device-local. Settings shows authorization state, links to system notification settings when access is denied, and can schedule a sample preview using the selected privacy level. Authenticated rule loads and saves refresh an account-scoped Keychain cache containing only the encrypted Product Sync payload. Successful authenticated categorization reads separately refresh an encrypted, account-scoped, device-only snapshot of the System and Custom Categories and exact-sender Future Learning Signals, including explicit absence. Future Learning Signal entries expire after 24 hours; the categorization snapshot is replaced by the next authenticated refresh, including explicit absence, and the cache is cleared on sign-out or Product Account change. After the production Product Account connection accepts an Apple identity token, the client records its `exp` timestamp in the device-only session snapshot. A Gmail background wake uses the rules cache only after Product Sync returns an authentication rejection for that previously accepted session, the recorded timestamp is expired, and Apple still reports the credential as authorized. A session without that verified timestamp or an active token, or with revoked, missing, or unavailable Apple authorization, a trusted-device rejection, or an unrelated network or server failure remains fail-closed. The wake uses the categorization cache only after a remote categorization read fails; it can then schedule a visible local notification only after the trusted device fetches the new message, categorizes it locally, confirms the Mail Profile assigned to the Mailbox Connection and its policy permit delivery, and matches any of its categories against those rules. Notification deep links carry the Profile and Mailbox Connection identifiers so inactive-Profile notifications reopen in the right context. Missing, stale, corrupt, or sender-mismatched categorization context leaves the message uncategorized; foreground categorization remains network-authoritative. A successful authenticated load of an empty rule set clears stale cached rules. After local encryption succeeds, a save attempt invalidates its prior rule cache before contacting Product Sync, so a network or authentication failure cannot leave changed or removed rules available to background processing. Cache fallback remains unavailable until a later authenticated load, successful save, or conflict response also succeeds in writing the authoritative payload to Keychain. Rules are empty by default. The separate device-only Generic Notification Fallback is also off by default; when the user enables it, failed, incomplete, or out-of-time category processing may instead schedule a content-free new-mail notification. The fallback does not sync and does not expose Notification Rules, categories, or message content to the backend. See [ADR 0008](docs/adr/0008-device-evaluated-category-aware-notifications.md).

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

The first app screen is the Product Account path. It lets a user sign in with Apple, create or resume a Product Account, and register the current trusted device with the backend using only Operational Account Data. After sign-in, the adaptive mail shell becomes the root experience; the current Account Settings sheet contains diagnostics and raw backend health. Development builds expose adaptive Settings destinations for Email Accounts, Account & Devices, device-local Appearance, and Privacy & Data.
Account & Devices keeps Product Account identity separate from Mailbox Connections, lists, renames, and remotely revokes other Trusted Devices, manages the Recovery Key after recent Sign in with Apple authentication, signs the current device out while unregistering its push route and clearing account-scoped local state, and permanently deletes the Product Account after fresh Apple authentication and explicit confirmation. Initiating remote revocation requires connectivity and immediately blocks Product Account APIs and push routing. Product Sync key rotation may complete after the workflow removes an offline device; remaining devices adopt the rotated key when they reconnect. The revoked app purges local Product Account data, mailbox credentials, and cached mail when it reconnects; launch-time cleanup applies only when a persisted revocation marker already exists. Offline copies cannot be erased remotely. After the first revocation, registration of previously unseen device identifiers remains locked until an explicit device-bound enrollment flow is available, preventing a revoked client from bypassing its tombstone by minting a new identifier.
Product Account deletion requires connectivity, keeps the account usable while retrying Apple revocation, then fences the account and schedules backend cleanup to completion across bounded batches before reachable clients purge account-scoped local credentials and data. It never deletes provider mail and does not promise to revoke provider-issued authorization; Gmail or Microsoft authorization may require separate revocation. Configure the Convex deployment with `APPLE_SIGN_IN_KEY_ID`, `APPLE_SIGN_IN_PRIVATE_KEY`, and `APPLE_TEAM_ID` alongside `APPLE_BUNDLE_ID` to enable the Apple token exchange and revocation. The Recovery Key and decrypted Product Sync data never leave the device; Convex stores only the opaque encrypted account-key wrapper.
On iPhone and iPad, the signed-out Product Account screen also opens Appearance and Privacy & Data directly; Mac Catalyst uses its Settings window. Appearance applies System, Light, or Dark theme, Dynamic Type-relative reading size, sender or system message-body typography, and optional increased contrast immediately across the app; its live message-list and reader preview is also available before sign-in. Privacy & Data stores Ask, Never, or Always Load Remote Message Content choices and On Demand, Wi-Fi, or Always attachment-download choices only on the device. A Mailbox Connection can override the global remote-content choice, while one-message consent never changes it; the reader enforces the effective choice without weakening tracking-pixel filtering or the isolated remote-image loader. Gmail message presentations expose ordinary MIME attachments without treating inline CID images as files; attachment requests are size-bounded, cancellable, persisted with complete file protection in a 250 MB oldest-file-evicted store, cleared with their Mailbox Connection or Product Account, and initiated only when the selected device-local network policy permits them. Device-local search indexes only static destination, group, section, and control labels; contextual authorization links can open and briefly highlight the affected connection without indexing mailbox addresses or content. Settings restores the last available destination, prompts before navigation discards an edited connection, and shows only actionable authorization or synchronization indicators. Production builds keep the current Account Settings entry point until every Settings destination meets the release gate; the completed redesign will move diagnostics to Advanced.

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

When mise is not activated in the shell, prefix the lint command with `mise exec --`.

```sh
zsh scripts/check-apple-lint.zsh
xcodebuild test -project apps/unwired-mail/unwired-mail.xcodeproj -scheme unwired-mail -destination 'platform=iOS Simulator,name=iPhone 17'
```

The Apple app approves and exact-pins SwiftMail 1.10.0 behind `MailEngine`; externally distributed Release builds keep Standards-Based Mailbox Connections unavailable until issue #280 records passing iCloud Mail and Fastmail certification. Dependency approval and provider certification are separate gates. See [the SwiftMail engine guide](docs/qualification/swiftmail-experimental-engine.md) for the exact commit, build policy, safety boundary, and local validation. The secrets-backed Provider Compatibility Run uses dedicated Provider Test Mailboxes/Tenants and produces redacted Mail Test Evidence. See [the Provider Compatibility Run runbook](docs/qualification/swiftmail-provider.md) for protected-environment setup, opt-in invocation, evidence, and the manual soak checklist.

## Automated code review

[CodeRabbit](https://docs.coderabbit.ai/getting-started/yaml-configuration)
uses the repository-root [`.coderabbit.yaml`](.coderabbit.yaml) together with
the nearest `AGENTS.md` instructions. It automatically reviews non-draft pull
requests to the default branch and incrementally reviews new pushes. Pull
requests from common dependency and automation bots are skipped, as are pull
requests whose title contains `[WIP]` or `[skip review]` or that carry the
`do-not-review` label. Because CodeRabbit skips bot-authored pull requests by
default, [`.github/workflows/coderabbit-bot-review.yml`](.github/workflows/coderabbit-bot-review.yml)
explicitly requests reviews for non-draft pull requests authored by
`gipity-bot[bot]` when they are opened, reopened, receive new commits
(`synchronize`), or become ready for review (`ready_for_review`). Generated
Convex client files are excluded from review.

Codex can close the feedback loop with a
[Scheduled task](https://learn.chatgpt.com/docs/automations?surface=app) and the repository-local
[`babysit-pr`](.agents/skills/babysit-pr/SKILL.md) skill. Create a scheduled task
in Work, select this project with an isolated worktree, and run it every 30
minutes as the authoritative recovery sweep:

```text
Use $babysit-pr to sweep every open ready-for-review same-repository pull
request in unwired-dev/product.
```

The task excludes drafts, includes ready PRs without review threads, and ignores
fork heads. For each PR it first merges the actual base into a stale or
conflicted head, then independently validates automated review findings and
repairs current, attributable GitHub Actions failures. It pushes with the GitHub
App identity, requests Codex review after writes, replies to and resolves
conclusively addressed threads after their fixes or evidence are pushed, and
waits independently for required CI plus current-head Codex and CodeRabbit
responses before completing the pass. The CodeRabbit gate is not applicable
when the trusted configuration excludes the PR. Required CI passes only when it
concludes success or skipped; cancelled required checks remain pending. Verified
maintainer decisions take precedence over automated reviewers, and compact per-
PR state outside disposable worktrees lets later runs resume safely. The task
performs trusted-base validation on the host outside the Codex command sandbox,
but only as a dedicated non-privileged credential-free OS identity or on an
equivalently isolated ephemeral runner that cannot access the Scheduled-task
identity's home, login keychain, credential stores, or agent sockets. Each run
uses a run-owned home and temporary directory set, an empty keychain, an allow-
listed environment, a dedicated temporary clone, and run-owned build and
Simulator resources. If that boundary is unavailable, the task reports
validation as unavailable instead of executing PR-controlled code as the
credentialed Scheduled-task identity. It cleans up every temporary keychain,
process, Simulator, XCTest clone, and PR worktree it creates. It never merges or
approves a pull request and never triggers CodeRabbit. The Scheduled-task
identity must have the GitHub integration, `gh`, `gipity-gh`, and `gipity-git`
configured; do not expose those credentials to the validation identity.

To attach a concern to the next sweep from a top-level PR comment, a repository
maintainer can use this exact first nonblank line:

```text
@gipity-bot babysit
```

Optional concern text can follow on later lines. The task verifies live
`write`, `maintain`, or `admin` permission, treats the text as a concern rather
than executable instructions, and reuses matching persisted and live outcome
replies. It posts a new reply only when the command or PR head changes the
materially evidenced state.
Other top-level comments are report-only; unresolved review threads continue to
be assessed automatically.

Scheduled tasks are time-triggered. Do not add a GitHub Action that merely
posts `@codex` comments or starts a second coding agent: it would not share the
task's owner-only lease state and could race the authoritative writer. A future
event-driven wakeup for review comments, completed CI, or base-branch updates
must target a published Workspace Agent through the
[trigger API](https://learn.chatgpt.com/workspace-agents/trigger-runs), use an
idempotency key per GitHub delivery, and share the same durable per-PR
coordination store before it is allowed to mutate PRs. Keep the 30-minute sweep
active as recovery even after such a bridge is configured.

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
- [Mail test environment implementation plan](docs/mail-test-environment.md)
- [Gmail Provider Test Tenant provisioning](docs/gmail-provider-test-tenant.md)
- [Scheduled Send and Send Reminder implementation plan](docs/scheduled-send.md)
- [Architecture decisions](docs/adr/)
- [Agent instructions](AGENTS.md)
