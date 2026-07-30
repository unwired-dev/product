# Settings redesign

Status: implementation in progress. The adaptive shell and Email Accounts destination are
available through development-only entry points; production still uses Account Settings.

## Goal

Replace the current single-scroll Account Settings sheet with one adaptive Settings experience. Wide layouts use a grouped navigation sidebar and one detail pane. Compact layouts preserve the same information architecture as a navigable settings list.

The released experience must not contain empty or “Coming Soon” destinations. Work may land incrementally behind development-only access, but every visible destination must have functional core controls before the new Settings entry points are enabled.

## Information architecture

| Group | Destination | Purpose |
| --- | --- | --- |
| Accounts | Email Accounts | Manage Mailbox Connections, authorization, sending identity, and synchronization |
| Accounts | Account & Devices | Manage the Product Account, Trusted Devices, recovery, sign-out, and deletion |
| Mail | Inbox | Configure inbox presentation and launch behavior |
| Mail | Reading | Configure Message Read State and Read Receipt behavior |
| Mail | Swipes | Assign message actions to leading and trailing swipe gestures |
| Composing | Compose | Configure general drafting, replying, forwarding, and Undo Send behavior |
| Composing | Signatures | Create signatures and assign them to Mailbox Connections |
| Composing | Templates | Create reusable message subjects and bodies |
| Automation | Categories | Configure System Categorization, the Custom Category, and historical categorization |
| Automation | Notifications | Configure category-aware notification eligibility and device presentation |
| Application | Appearance | Configure device-local theme and reading presentation |
| Application | Privacy & Data | Configure remote content, downloads, local storage, encryption information, and export |
| Application | Advanced | Inspect sync health, run redacted diagnostics, and rebuild local state |
| Application | About | Show product, policy, support, version, and license information |

“Destination” is the canonical UI term for a sidebar item. These items are not independent tab bars.

## Platform behavior

- macOS uses a dedicated Settings window available from the app menu and `Command-,`.
- Regular-width iPad layouts use the two-pane Settings layout in a resizable sheet.
- iPhone and compact-width iPad layouts use a full-height sheet with a settings list that pushes destinations.
- Email Accounts is selected the first time Settings opens after Product Account sign-in. Before sign-in, Appearance is selected first so an available destination is shown.
- Later openings restore the last destination on that device. A missing destination falls back to Email Accounts after sign-in or Appearance before sign-in.
- macOS does not add a Done button to its Settings window. iPhone and iPad use platform-appropriate dismissal controls.
- The same destination registry, labels, grouping, search metadata, and deep-link routes drive every platform layout.

## Navigation and search

Settings search runs only on the device. It matches destination names, section names, and control labels, then opens and briefly highlights the selected control. Diagnostic content and reports, mailbox content, account addresses, and signature or template bodies are never searched; labels for diagnostic controls, such as Run diagnostics and Export a redacted diagnostics report, remain searchable.

Contextual product actions may deep-link to a destination and control:

- Authorization or sync failure opens the affected Mailbox Connection in Email Accounts.
- Notification permission failure opens Notifications.
- Missing-signature actions open Signatures with the sending connection selected.
- Read-receipt prompts can open Reading.
- Storage warnings open Privacy & Data.
- Preference conflicts open the affected destination and field.

Normal Settings entry restores the last destination. A deep link never discards an edited entity without confirmation.

Sidebar indicators appear only when action is needed:

- Email Accounts: authorization or sync failure
- Account & Devices: recovery or device-security issue
- Notifications: operating-system permission denied
- Any synchronized destination: unresolved conflict or failed sync

A temporary pending-sync indicator may be shown. Decorative counts and permanent success badges are excluded. Selecting an indicated destination explains the issue at the top of its detail pane.

Unsupported provider capabilities remain visible in account-scoped views but disabled with a concise provider-specific explanation. Global selectors mark affected accounts instead of hiding them. An unsupported action is never silently replaced with a different action.

## Detail-pane behavior

The detail pane is a scrollable, readable-width form composed from native sections, controls, disclosure rows, and destructive-action treatments. Product color is limited to selection and primary actions. Dashboard cards, oversized decorative headings, and gradients are excluded.

Simple toggles, pickers, and swipe assignments save immediately. Multi-field entities—Mailbox Connections, signatures, templates, and the Custom Category—use explicit Save and Cancel actions. Leaving an edited entity prompts the user to discard changes or keep editing. A sync error or conflict appears only in the affected destination.

Settings updates apply to the running mail experience without requiring an app restart. Manual
provider refreshes notify the separate mail shell after the Settings-owned connection snapshot
finishes loading without immediately reloading that same router again. A Settings presentation
that shares the mail shell's view model treats the completed refresh as the update and does not
invoke another router load. The routed-provider and generic-mail snapshots start together, and
generic setup remains disabled until its synchronized definition snapshot finishes loading.
Microsoft, EWS, and generic provider mutations also remain disabled while the routed snapshot is
loading, so mutation-triggered router refreshes cannot overlap the initial load.
The generic-mail Manage menu offers Default Sending Connection only when the routed snapshot
contains the same authorized connection with sending capability; read-only IMAP routes and
unrouted POP3 definitions cannot become the default sender.

## Destination requirements

### Email Accounts

The app-scoped Product Account session shares one bootstrap task across mail windows, so closing
the first window cannot cancel session restoration for surviving windows. Each mail window
registers its own mailbox-work cancellation and busy state, and row-level synchronization
notifies every open mail shell to reload observed metadata. Manual row synchronization remains
disabled while the provider snapshot is partial because freshness state is not authoritative.

- List every Mailbox Connection with provider, address, authorization state, and sync health.
- Add a Mailbox Connection.
- Select the Default Sending Connection.
- Open one connection's detail within the detail pane.
- Authorize, reauthorize, or remove Mailbox Authorization from the current device.
- Review and edit non-secret connection or server settings when supported.
- Map required Mailbox Roles.
- Show last synchronization and Historical Metadata Backfill progress and provide manual synchronization.
- Remove a Mailbox Connection everywhere.
- Link to connection overrides in Signatures, Notifications, and Reading instead of duplicating those controls.

### Account & Devices

- Show Product Account identity.
- List Trusted Devices and identify the current device.
- Rename or revoke a Trusted Device.
- Show Recovery Key status and support generation and replacement.
- Sign out on the current device.
- Delete the Product Account after recent authentication and explicit confirmation.

Device Revocation immediately blocks Product Account APIs and push routing, then rotates Product Sync key material for remaining Trusted Devices. It remains incomplete until the new key epoch is durably committed and every remaining Trusted Device has fenced on it; future ciphertext cannot use the old key. When the revoked app reconnects, it must purge local product data, credentials, and provider credentials stored in the Keychain. Settings must explain that revocation cannot erase data already copied from an offline or compromised device and that provider authorization may need separate revocation.

Delete Product Account is immediate and irreversible. It deletes backend operational account data, encrypted Product Sync payloads, and push routes and asks reachable devices to purge local product data, credentials, and provider credentials stored in the Keychain. Offline or compromised devices may retain local copies until they reconnect and process the purge or account-rejection rule. It never deletes provider mail or promises to revoke provider-issued authorization.

Billing and subscriptions are excluded until the product has a commercial plan.

### Inbox

- Thread-list density: compact, comfortable, or spacious
- Preview length: none, one, two, or three lines
- Show contact images
- Show Category badges
- Show attachment indicators

Defaults are Unified Inbox with the Important Mail View at the start of each application session, comfortable density, two preview lines, and shown contact images, Category badges, and attachment indicators.

Thread grouping, latest-message ordering, source-connection identity in Unified Inbox, and the latest message opening expanded remain fixed product behavior.

The actual inbox and message browser remain in the main mail experience and are removed from Settings.

### Reading

Read State:

- Mark an opened message read immediately, after one, three, or five seconds, or manually.
- Opening a Thread marks only the expanded message read.
- Optionally mark the entire Thread read when replying.
- Optionally mark archived or deleted messages read.
- Allow a per-connection override only where provider behavior differs.

Read Receipts:

- Incoming requests: Ask Every Time by default, or Never.
- Incoming receipts are never sent silently; there is no Always Send option.
- Outgoing requests: Off by default, with Never, Ask While Sending, or Request by Default.
- Support per-connection overrides.
- Explain that receipts are best-effort and depend on recipient and provider support.

The account-wide incoming and outgoing defaults and each per-connection override are encrypted Mail Workflow Preferences.

### Swipes

- Assign up to two leading-edge and two trailing-edge actions.
- Available actions are Read/Unread, Archive, Trash, Pin/Unpin, Move, and Spam/Not Spam.
- Labels adapt to current message state.
- A separate toggle controls whether a full swipe performs the outermost action.
- Assignments are global Mail Workflow Preferences.
- An unsupported provider action is omitted for that message and is never replaced silently.
- Use the same assignments for iPhone and iPad touch gestures and macOS trackpad swipes where supported.

### Compose

- Undo Send: Off, 10, 20, or 30 seconds; default 10 seconds.
- Default format: rich text with a plain-text alternative.
- Default reply action: Reply, never Reply All.
- Choose the synchronized default Composer Presentation Preference: partial-height or full-screen.
- Choose whether the synchronized Formatting Toolbar Preference shows the formatting toolbar.
- Include quoted text collapsed beneath the draft.
- Include original attachments when forwarding.
- Link to system-owned spelling and automatic-correction settings.
- Allow per-connection formatting or reply/forward overrides only when required.

Undo Send is a pre-provider Outbox delay. Cancelling during the window prevents provider handoff; the product never describes it as recalling mail already accepted by a provider.

Default sender selection remains in Email Accounts.

### Signatures

- Create multiple named signatures.
- Synchronize signatures through End-to-End Encrypted Product Sync.
- Assign separate per-connection defaults for new messages and replies/forwards.
- Allow a different signature to be chosen while composing.
- Support basic formatting and links and generate a plain-text alternative.
- Place signatures above quoted reply text.
- Exclude remote images, tracking pixels, and externally hosted assets.
- Defer local embedded images.

### Templates

- Create multiple named templates synchronized end-to-end.
- Store a subject and formatted message body.
- Create a new draft from a template or insert a template into the current draft.
- Keep templates global while requiring the user to choose or confirm the sending connection.
- Exclude default recipients, attachments, signatures, and dynamic placeholders from the initial version.
- Never send automatically.
- Never overwrite existing draft content without confirmation.

### Categories

- Master switch for automatic categorization of new mail.
- Enable or disable System Categories, including People, Invites, Orders, Newsletters & Promotions, and Flights, without renaming them.
- Create, edit, and delete multiple Custom Categories with names and descriptions.
- Choose a curated SF Symbol and accessibility-tested color when creating or editing a Custom Category; the shared reader and Settings flows use the same appearance chooser.
- Run Bounded Historical Categorization by Mailbox Connection, date range, mailbox, and category target.
- Show progress and allow cancellation.
- Reset learned sender signals after confirmation.

Disabling a Category stops future System Categorization into it but preserves existing Message Categories. Resetting learning affects only future categorization: the reset first advances a synchronized learning generation, then invalidates Future Learning Signal payloads and the current device's cached learning context. Every automatic, manual, and historical categorization run captures that generation before work begins and discards results or merged signals from an older generation, so reset learning cannot reappear. Cancelling a historical run preserves assignments already completed.

### Notifications

- Show operating-system authorization status and link to System Settings when permission is denied.
- Global notification switch, synchronized as a Mail Workflow Preference, with per-connection overrides.
- Choose notifying Categories per connection.
- Configure the device-local Generic Notification Fallback.
- Lock-screen content level: count only, sender, sender and subject, or full preview; this device-local choice applies to category-aware notifications and defaults to count only.
- Sound and badge toggles.
- Quiet schedule with an allowlist for selected Categories.
- Explain which controls synchronize and which remain device-local.
- Preview a sample notification without sending mail.

The global notification switch, category eligibility, and per-connection notification policy are encrypted Mail Workflow Preferences. Operating-system authorization, Generic Notification Fallback, lock-screen presentation, sound, badge, and quiet schedule are Device-Local Preferences.

Notifications default to a disabled global switch with no eligible Categories or per-connection overrides; Generic Notification Fallback and quiet schedule are disabled, while sound and badge use the operating-system default.

### Appearance

- Theme: System, Light, or Dark; default System
- Reading text size while respecting Dynamic Type
- Message-body presentation: sender formatting, system serif, or system sans-serif
- Optional increased contrast beyond the system default
- Live message-list and reader preview

Inbox density remains in Inbox. Arbitrary accent colors, custom fonts, and a duplicate reduced-motion setting are excluded. Appearance is device-local.

### Privacy & Data

- Remote Message Content policy: Ask by default, Never, or Always Load.
- Block known Tracking Pixels even when other remote content is allowed.
- Per-connection remote-content overrides.
- Attachment download policy: On Demand, Wi-Fi, or Always.
- Show local storage used by metadata, bodies, drafts, and attachments.
- Clear cached bodies and downloaded attachments without deleting provider mail.
- Explain Product Sync encryption and link to Recovery Key management.
- Summarize the Read Receipt policy and link to Reading.
- Export user-owned Product Sync data.
- State that message content is never sent to the product backend for AI processing.

Remote-content, download, and storage choices are device-local.

### Advanced

- Show overall mailbox sync and Product Sync health.
- Run diagnostics.
- Export a redacted diagnostics report containing no message content, addresses, provider credentials, Categories, or Product Sync plaintext.
- Rebuild local search and metadata indexes.
- Clear and resynchronize local mailbox data.
- Show app, backend-schema, and build versions.
- Explain the local and remote effects of destructive resets and require confirmation.

Raw backend health checks, environment switching, and test controls are debug-only. Provider server endpoints and Mailbox Role mapping remain under the affected Mailbox Connection in Email Accounts.

### About

- App version and build
- Privacy Policy and Terms
- Open-source acknowledgements and licenses
- Support contact
- Product website
- Copyright

Diagnostics, account identifiers, and environment information are excluded.

## Signed-out behavior

Settings remains available before Product Account sign-in:

- Appearance is available.
- Privacy & Data exposes local storage and remote-content defaults.
- Advanced exposes local diagnostics only.
- About is available.

Account-bound destinations remain visible but disabled with a concise sign-in explanation. This lets prospective users inspect privacy behavior without hiding the product's full capabilities.

## Preference ownership and synchronization

Mail Workflow Preferences follow the user through End-to-End Encrypted Product Sync:

- Inbox behavior
- Read-state rules
- Swipe assignments
- Compose behavior
- Signatures
- Templates
- Category configuration
- Global notification switch
- Notification category eligibility
- Per-connection notification policy
- Account-wide and per-connection Read Receipt policy

Device-Local Preferences remain on one device:

- Appearance
- Operating-system notification authorization
- Generic Notification Fallback
- Notification sound, badge, quiet schedule, and lock-screen presentation
- Remote-content and download behavior
- Storage and diagnostics
- Last-opened Settings destination

Provider credentials remain in the current device's Keychain.

Device-local preferences always save offline. Mail Workflow Preferences save locally while offline, queue encrypted Product Sync updates, and show pending state, except the global notification switch, notification category eligibility, and per-connection notification policy: their Notification Rule save contract remains fail-closed as specified in [ADR 0008](adr/0008-device-evaluated-category-aware-notifications.md), so an uncertain remote write leaves no background-eligible rules cache. Non-overlapping fields merge automatically. If two devices change the same field from the same older revision, both values are preserved for explicit resolution; device clocks, upload order, and device identity never silently choose the winner. Signatures and templates may preserve the competing value as a conflict copy.

Device Revocation, Delete Product Account, Mailbox Connection removal, authorization or reauthorization, server verification, and Mailbox Role remapping require connectivity and cannot appear complete offline. Removing Mailbox Authorization from the current device remains available offline and immediately deletes its local Keychain credentials and cached mailbox data.

## Migration

Migration is idempotent and never resets settings merely because the new UI opens:

- Preserve every Mailbox Connection and the Default Sending Connection.
- Preserve the existing Custom Category.
- Migrate existing Notification Rules into the synchronized Notification category eligibility preference, preserving their selected Category IDs as the global default; each connection inherits that default until the user creates an override. Enable the global notification switch when migrated rules are non-empty and leave it off when they are empty. Before these migrated controls become authoritative, advance the [ADR 0008](adr/0008-device-evaluated-category-aware-notifications.md) minimum-client generation fence, invalidate older payloads and cached rules, and wait until every Trusted Device acknowledges that generation or is revoked.
- Preserve the current device's Generic Notification Fallback.
- Initialize genuinely new preferences from the explicit defaults in this document.

## Implementation boundary

Settings becomes a separate feature instead of expanding `AccountView.swift`:

- `Features/Settings/SettingsScene`
- A typed destination and group registry
- One focused view per destination
- Focused preference stores and sync services
- Reuse existing account, category, notification, and connection models where they already express the required behavior
- Keep AccountView responsible for the mail experience and for opening Settings

Concrete names may follow nearby repository conventions, but the destination registry must remain the single source for grouping, labels, icons, search metadata, signed-out availability, and deep-link routing.

## Delivery plan

Implementation is tracked by [#115](https://github.com/unwired-dev/product/issues/115), [#116](https://github.com/unwired-dev/product/issues/116), [#117](https://github.com/unwired-dev/product/issues/117), [#118](https://github.com/unwired-dev/product/issues/118), [#119](https://github.com/unwired-dev/product/issues/119), [#120](https://github.com/unwired-dev/product/issues/120), [#121](https://github.com/unwired-dev/product/issues/121), [#122](https://github.com/unwired-dev/product/issues/122), [#123](https://github.com/unwired-dev/product/issues/123), [#124](https://github.com/unwired-dev/product/issues/124), [#125](https://github.com/unwired-dev/product/issues/125), [#126](https://github.com/unwired-dev/product/issues/126), [#127](https://github.com/unwired-dev/product/issues/127), [#128](https://github.com/unwired-dev/product/issues/128), [#129](https://github.com/unwired-dev/product/issues/129), [#130](https://github.com/unwired-dev/product/issues/130), [#131](https://github.com/unwired-dev/product/issues/131), [#132](https://github.com/unwired-dev/product/issues/132), and [#133](https://github.com/unwired-dev/product/issues/133). Each issue is a tracer-bullet slice with native blocking relationships.

1. Add the Settings feature shell, adaptive navigation, search, and deep-link routing.
2. Add versioned preference schemas, device-local persistence, encrypted synchronization, migration, offline queueing, and conflict resolution.
3. Migrate existing Email Accounts, Categories, Notifications, Account & Devices, and Advanced functionality.
4. Implement Inbox, Reading, Swipes, Compose, Signatures, Templates, Appearance, Privacy & Data, and About.
5. Implement device revocation, Product Account deletion, data export, diagnostics, and remaining backend support.
6. Enable the production Settings entry points and remove the old Account Settings sheet.

Each slice includes its own tests and documentation. The new production entry points remain disabled until all destinations meet the release requirements.

The first delivered slice provides the typed destination registry, adaptive compact and
regular-width navigation, a dedicated Mac Catalyst Settings window with Command-, support,
and complete Mailbox Connection management in Email Accounts. It reuses the existing
provider controls so authorization, default-sender selection, synchronization, non-secret
connection settings, Mailbox Role mapping, and removal retain their established behavior.
The Mac Catalyst Settings window shares the app's Product Account session, so sign-out moves the
shared session out of its signed-in state before cleanup begins, immediately removing mailbox
controls from every window. Provider changes notify the active mail shell. Email Accounts prunes
shared freshness state only after every provider adapter returns an authoritative connection
snapshot. Snapshot authority is published with the replacement list and checked by every
synchronization entry point, so direct refreshes, runtime observers, and manual synchronization
cannot apply a partial list using stale authority. A partial provider load keeps healthy providers
visible without cancelling or pruning sync state for providers that could not load, while surfacing
the provider failure for retry. Generic-mail removal uses the snapshot-aware refresh path after a
failed removal and the same shared mailbox-work busy state and cancellation boundary as Gmail,
Microsoft, and EWS removal.

## Release gate

- Unit tests cover defaults, persistence, migration, per-connection overrides, offline queueing, and conflicts.
- Navigation tests cover grouping, search, deep links, save/discard behavior, capability explanations, and signed-out availability.
- UI tests cover iPhone compact width, iPad regular and compact widths, and the macOS Settings window.
- Accessibility validation covers VoiceOver labels, keyboard navigation, focus order, Dynamic Type, contrast, and reduced motion.
- Regression tests prove existing connections, Categories, Notification Rules, and Generic Notification Fallback survive migration.
- Apple formatting, lint, and the relevant full test suite pass.
- When a slice touches Convex or other TypeScript support, `pnpm lint`, `pnpm format`, `pnpm turbo run check-types`, `pnpm test`, and `pnpm fallow` pass.

## Related decisions

- [ADR 0001: End-to-end encrypted Product Sync](adr/0001-end-to-end-encrypted-product-sync.md)
- [ADR 0010: Device-local mailbox authorization](adr/0010-device-local-mailbox-authorization.md)
- [ADR 0019: Sync mail workflow preferences, not device state](adr/0019-sync-mail-workflow-preferences-not-device-state.md)
- [ADR 0020: Revoke devices with Product Sync key rotation](adr/0020-revoke-devices-with-sync-key-rotation.md)
- [ADR 0021: Delete Product Accounts immediately](adr/0021-delete-product-accounts-immediately.md)
- [ADR 0022: Save workflow preferences offline with explicit conflicts](adr/0022-save-workflow-preferences-offline-with-explicit-conflicts.md)
