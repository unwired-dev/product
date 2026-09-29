# Privacy, storage and synchronization

[Domain index](../../CONTEXT.md) · [behavior notes](../product/privacy-and-sync.md)

Privacy and encryption boundaries remain applicable. Category-Aware Notification
and Generic Notification Fallback retain prototype meanings; replacement
notification behavior comes from
[ADR 0063](../adr/0063-notify-for-new-inbox-mail-without-categorization.md).

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**Durable Message Metadata**:
Message-identifying and mailbox state data retained locally to support sync, display, and categorization without retaining full bodies by default.
_Avoid_: Full message archive

**Initial Mailbox Availability**:
The state in which metadata for the newest 50 messages, or all provider-visible messages when fewer exist, is list-visible and usable before the rest of a newly connected mailbox has synchronized; bodies remain on demand or subject to separate body-cache prefetch rules.
_Avoid_: Completed mailbox synchronization, full initial sync

**Historical Metadata Backfill**:
Resumable background synchronization of the complete provider-visible message history as **Durable Message Metadata** after **Initial Mailbox Availability**.
_Avoid_: Blocking initial sync, historical categorization

**Mailbox Sync Status**:
The visible per-connection state of authorization, synchronization, last success, offline operation, backfill, or failure.
_Avoid_: Blocking loading state, hidden sync error

**Bounded Encrypted Body Cache**:
Locally encrypted storage for prefetched recent readable body representations and opened older readable body representations, excluding attachments and constrained by eviction controls.
_Avoid_: On-demand-only body cache, permanent body store, attachment archive

**Remote Message Content**:
Content referenced by a message but fetched from an external server only for an authorized message presentation, such as remote images. After that fetch, the client may restore it from the **Authorized Remote Content Cache** without contacting the server again.
_Avoid_: Message body, downloaded attachment

**Authorized Remote Content Cache**:
The separate 250 MB device-wide encrypted store for non-tracking **Remote Message Content** fetched after a person or their explicit loading policy authorized it. Its quota is shared, but every entry is encrypted and namespaced by Product Account, Mail Profile, Mailbox Connection, stable message identity, and resource revision without cross-Profile deduplication. It evicts least-recently-used entries first, protects content currently displayed, and retains hidden bytes after a Never-policy change until eviction or manual removal through Clear Remote Content.
_Avoid_: Browser cache, Bounded Encrypted Body Cache, automatic remote-content permission

**Tracking Pixel**:
Remote message content intended to reveal that a message was opened or viewed.
_Avoid_: Read Receipt, ordinary embedded image

**Minimal Push Metadata**:
The smallest mailbox-change data the backend may see to route sync wakeups to trusted devices.
_Avoid_: Server-side mailbox sync, backend mail access

**Best-Effort Background Freshness**:
A mailbox freshness promise where trusted devices process provider signals and system-granted background opportunities without claiming guaranteed instant background delivery.
_Avoid_: Guaranteed real-time delivery, server-hosted mailbox sync

**Category-Aware Notification**:
A notification shown only after local categorization determines the message matches the user's notification rules.
_Avoid_: Generic new-mail notification

**Notification Rule**:
User-owned preference that controls which newly arriving messages can produce visible notifications for a **Mailbox Connection**.
_Avoid_: Backend routing rule

**New Mail Notification**:
A device-evaluated notification for newly arriving Inbox mail from an enabled **Mailbox Connection**, distinct from historical synchronization results.
_Avoid_: Historical-mail alert, Category-Aware Notification, Generic Notification Fallback

**Generic Notification Fallback**:
An optional user setting that allows a visible new-mail notification when category-aware notification processing cannot finish in time.
_Avoid_: Default generic notification

**Return-to-Attention**:
A default-on, per-Mail Profile preference permitting the current notification-owning Trusted Device to request an interruption for a due Thread Snooze, Follow-Up Nudge, or Send Reminder. Presentation remains subject to Quiet State, Profile Lock, OS notification authorization, and device-local lock-screen content policy.
_Avoid_: Return to Attention, guaranteed reminder, automatic send

**Quiet State**:
A Mail Profile's interruption-suppression state, synchronized through **End-to-End Encrypted Product Sync**, that may be inactive, indefinite, or active until an absolute instant. While active, it suppresses visible notifications and proactive suggestions without suspending mailbox synchronization, indexing, Outbox, or Scheduled Send work.
_Avoid_: Quiet, Profile Quiet, Profile Lock, paused synchronization

**Profile Lock**:
Device-local protection scoped to one Product Account and Mail Profile that requires device-owner authentication before mail UI or search can reveal Profile content, with a device-local background grace period. Lock removes the Profile's Spotlight entries and suppresses content-bearing notifications while background work continues.
_Avoid_: Quiet State, Product Sign-In, synchronized lock

**Spotlight Mail Indexing**:
An off-by-default Device-Local Preference scoped to one Product Account and Mail Profile that permits a complete-file-protection Spotlight index of only sender, recipients, subject, date, Profile, Mailbox Connection, and opaque exact-message deep-link metadata. It excludes bodies, attachments, Product Sync, and the product backend, and removes stale entries on lock, disablement, authorization revocation, message deletion, connection transfer, or Profile deletion.
_Avoid_: Full-text mail index, synchronized search index, backend search

**Product Sync**:
Synchronization of product-owned user data across devices through the product's backend.
_Avoid_: iCloud sync, provider sync

**End-to-End Encrypted Product Sync**:
**Product Sync** where synced product data is readable only by the user's trusted devices.
_Avoid_: Server-readable sync, plaintext sync

**Mail Workflow Preference**:
A user-owned choice about handling mail that follows the user across trusted devices through **End-to-End Encrypted Product Sync**.
_Avoid_: Device setting, provider credential

**Device-Local Preference**:
A choice tied to one device's hardware, operating-system permission, appearance, storage, or diagnostics.
_Avoid_: Synced mail workflow

**Preference Conflict**:
Two changes to the same field of a **Mail Workflow Preference** that were made from the same older synchronized revision.
_Avoid_: Non-overlapping edit, upload-order winner

**Recovery Key**:
A user-held secret that can restore access to encrypted product data when no trusted device is available.
_Avoid_: Password reset, support recovery
