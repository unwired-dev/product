# Historical domain discussions

Archived on 2026-09-28 when the vocabulary in `CONTEXT.md` was split by topic.
These example dialogues and resolved ambiguities preserve the earlier interview
record, including prototype and replacement decisions. They are historical
evidence, not an active specification or a second glossary.

Use the [domain index](../../CONTEXT.md) for canonical definitions and the
[documentation index](../README.md) for current scope. In particular,
[ADR 0062](../adr/0062-keep-queued-delivery-on-its-originating-device.md)
supersedes cross-device delivery takeover, and
[ADR 0063](../adr/0063-notify-for-new-inbox-mail-without-categorization.md)
supersedes prototype notification defaults.

## Example dialogue

> **Dev:** "Should the first version support Android?"
> **Domain expert:** "The **Private email client** launches on iOS, iPadOS, and macOS. Android and Windows are future targets."
> **Dev:** "Can we rely on Apple Mail as the source of messages?"
> **Domain expert:** "No — this is a **True email client**, so it connects to providers directly."
> **Dev:** "Can users archive, delete, reply, and use provider-native mailbox actions?"
> **Domain expert:** "Yes — a **True email client** supports **Provider Mail Actions**."
> **Dev:** "Should the provider layer be fully neutral from day one?"
> **Domain expert:** "Use **Gmail-first provider support**. The first release supports Gmail; IMAP/SMTP and Microsoft 365 follow later."
> **Dev:** "Does supporting multiple accounts mean switching between multiple product sign-ins?"
> **Domain expert:** "No — one **Product Account** may own multiple **Mailbox Connections**."
> **Dev:** "Can a second trusted device reuse the first device's provider credentials?"
> **Domain expert:** "No — the **Mailbox Connection** synchronizes without secrets, and each device obtains its own **Mailbox Authorization**."
> **Dev:** "Is IMAP alone enough for a generic provider?"
> **Domain expert:** "No — a **Standards-Based Mailbox Connection** uses IMAP for mailbox access and SMTP for sending."
> **Dev:** "Is the inbox tied to one mailbox connection?"
> **Domain expert:** "Not always — a **Unified Mailbox** combines the corresponding messages from every **Mailbox Connection**, while each connection also exposes its own mailboxes."
> **Dev:** "Does Outbox contain mail that was already sent?"
> **Domain expert:** "No — the **Sent Mailbox** contains successfully sent messages; the **Outbox** is a temporary queue for pending, retrying, or failed delivery."
> **Dev:** "Does pinning a Gmail Thread add stars to its messages?"
> **Domain expert:** "No — a **Pin** is product-owned, syncs by **Stable Thread Identity** across trusted devices, and does not change provider flags."
> **Dev:** "When a message is put in a **Category**, should Gmail see that as a label?"
> **Domain expert:** "No — it should be a **Synced Category** that stays inside the product across Apple devices."
> **Dev:** "Can automatic categorization create Gmail labels or move IMAP folders in v1?"
> **Domain expert:** "No — **Message Categories** stay separate from **Provider Mail Actions** in v1."
> **Dev:** "Should category sync use iCloud?"
> **Domain expert:** "No — use a **Product Account** and **Product Sync**."
> **Dev:** "Can support inspect synced categories for debugging?"
> **Domain expert:** "No — **End-to-End Encrypted Product Sync** means only trusted user devices can read them."
> **Dev:** "Can a password reset recover encrypted categories?"
> **Domain expert:** "No — recovery requires a **Recovery Key** or an existing trusted device."
> **Dev:** "Should categorization apply to the whole conversation?"
> **Domain expert:** "No — assign zero or more **Message Categories** to each message, while the **Thread** only groups related messages."
> **Dev:** "How does a second device know which message an encrypted category assignment belongs to?"
> **Domain expert:** "Use the **Mailbox Connection** and **Stable Provider Message Identity** to match the same message across devices."
> **Dev:** "Can the system recategorize a message later?"
> **Domain expert:** "No — after **System Categorization**, only a **User Override** can change it."
> **Dev:** "Should old mail be categorized during account setup?"
> **Domain expert:** "No — use **New-Mail-Only Categorization** after that **Mailbox Connection** is added."
> **Dev:** "Should historical mail have a separate not-processed state?"
> **Domain expert:** "No — historical mail remains in **Uncategorized State**."
> **Dev:** "Can the user choose to categorize old mail?"
> **Domain expert:** "Yes — offer **Historical Categorization Opt-In** during onboarding or later."
> **Dev:** "If the user opts in, should every historical message be categorized?"
> **Domain expert:** "No — use **Bounded Historical Categorization** so the user selects the scope."
> **Dev:** "Are all categories created by the user?"
> **Domain expert:** "No — use **System Categories** for common email types and **Custom Categories** for the user's own needs."
> **Dev:** "Is a custom category only a name?"
> **Domain expert:** "No — a **Custom Category** can include a **Category Description** to guide classification."
> **Dev:** "Can classification always inspect the full email body?"
> **Domain expert:** "No — start with **Minimized Classification Input** and inspect body text only when needed."
> **Dev:** "Should the classifier always pick the closest category?"
> **Domain expert:** "No — leave the message in **Uncategorized State** when confidence is too low."
> **Dev:** "Can user corrections improve future automatic categorization?"
> **Domain expert:** "Yes — a **User Override** can become a **Future Learning Signal**, but it must not recategorize existing messages."
> **Dev:** "If two devices categorize the same message before syncing, which assignment wins?"
> **Domain expert:** "Use the **Category Conflict Rule** per membership: different Category changes merge, user action beats system action, and concurrent user removal beats addition."
> **Dev:** "Should the app permanently store every email body?"
> **Domain expert:** "No — store **Durable Message Metadata** and categorization, while using a **Bounded Encrypted Body Cache** for recent and previously opened body text."
> **Dev:** "Which message bodies should be prefetched?"
> **Domain expert:** "At each synchronization reference instant, select the newest up to 500 distinct Inbox and **Sent Mailbox** bodies from the preceding 30 days. Selected-recent bodies take priority in the cache-fitting protected set; bodies in pinned **Threads** remain eligible afterward for bounded protection. Candidates admitted by the same selection never evict one another; keep Spam, Trash, attachments, and older unpinned bodies on-demand, with Spam and Trash excluded even when their Thread is pinned."
> **Dev:** "Can the backend participate in push without holding mail provider tokens?"
> **Domain expert:** "Yes — it may use **Minimal Push Metadata** to wake trusted devices, but devices fetch mail themselves."
> **Dev:** "Can the app guarantee instant background delivery for every provider?"
> **Domain expert:** "No — **Best-Effort Background Freshness** preserves device-local mailbox authorization and reconciles delayed changes on the next available wake or foreground activation."
> **Dev:** "Should users get generic new-mail alerts?"
> **Domain expert:** "Yes. The focused release uses **New Mail Notifications** with generic content by default and optional sender/subject previews."
> **Dev:** "How does category-aware notification fallback work in the existing Swift prototype?"
> **Domain expert:** "That prototype shows a fallback alert only when the user enables **Generic Notification Fallback**. The replacement's **New Mail Notifications** do not depend on categorization."
> **Dev:** "Does signing in also authorize access to mail?"
> **Domain expert:** "**Product Sign-In** establishes identity. Connecting a mailbox also requires **Mailbox Authorization** from its **Mail Provider**."
> **Dev:** "Can the backend read category names for support?"
> **Domain expert:** "No — the backend may only read **Operational Account Data**."
> **Dev:** "Can the backend read notification preferences to optimize routing?"
> **Domain expert:** "No — a **Notification Rule** is encrypted user data and devices decide whether to show notifications."

## Flagged ambiguities

- "email app" was resolved as **Private email client**, with Apple platforms first and Android and Windows as future targets.
- "email app" was resolved as **True email client**, not an assistant layer on top of Apple Mail.
- "main actions" was resolved as **Provider Mail Actions**, not product category actions.
- "offline mail actions" was resolved as optimistic local changes backed by durable **Pending Provider Actions**, not silent failure or online-only interaction.
- "cross-account bulk actions" was resolved as capability-intersection actions with per-connection execution and partial-success reporting, not an all-or-nothing transaction.
- "multiple accounts" was resolved as multiple **Mailbox Connections** owned by one **Product Account**, not multiple product sign-ins.
- "duplicate account connection" was resolved as authorization or repair of the existing **Mailbox Connection**, not a second connection for the same **Stable Provider Mailbox Identity**.
- "mailbox credential sync" was resolved as synchronized non-secret **Mailbox Connections** with device-local **Mailbox Authorization**, not synchronized provider credentials.
- "generic provider authentication" was resolved as preferred OAuth with device-Keychain passwords or app passwords permitted over **Secure Mail Transport**; client certificates and enterprise SSO are deferred.
- "disconnect account" was split into **Remove Device Authorization** and **Remove Mailbox Connection Everywhere**, with distinct local and cross-device data scopes.
- "provider rollout" was resolved as Gmail-only for the first release, followed by IMAP/SMTP and Microsoft 365.
- "Exchange Web Services support" was resolved as **On-Premises Exchange Connections** only; Exchange Online and Microsoft 365 use Microsoft Graph.
- "POP3 support" was resolved as a limited **Legacy POP3 Connection** using POP3 and SMTP with product-owned organization, not an IMAP-equivalent synchronized mailbox.
- "IMAP support" was resolved as a complete **Standards-Based Mailbox Connection** using IMAP and SMTP, not read-only mailbox access.
- "provider action parity" was resolved as the **Full-Capability Mailbox Connection** contract for Gmail, IMAP and SMTP, Microsoft Graph, and EWS; POP3 retains its reduced contract.
- "generic mail transport security" was resolved as **Secure Mail Transport** with TLS 1.2 or newer and valid server identity, not plaintext or user-approved invalid certificates.
- "generic account setup" was resolved as device-side **Mailbox Service Discovery** with user review and manual fallback, not backend-assisted or silent endpoint guessing.
- "unified inboxes" was resolved as **Unified Mailboxes** shown alongside the mailboxes belonging to each **Mailbox Connection**, not provider folders shared between providers.
- "unified navigation" was resolved as permanent Inbox, Pins, Drafts, Sent, Archive, All Mail, Spam, and Trash; conditional **Outbox**; and connection-scoped provider folders and labels.
- "unified message list" was resolved as one time-ordered thread list with visible Mailbox Connection identity and stable selection, not account-grouped sections.
- "bottom tab" was resolved as a mailbox-scoped **Mail View**, not a **Category** or mailbox; Important and All Messages are permanent while the remaining views are user-configurable.
- "important email" was resolved as membership in the user-configured union of Categories shown by the permanent Important **Mail View**, not a separate classification or **Pin**.
- "configurable bottom tab" was resolved as a one-Category **Mail View**, not an arbitrary multi-rule query; only Important aggregates Categories.
- "visible Mail View capacity" was resolved as five on every supported Apple layout: two permanent views and up to three configurable Category views, without a v1 overflow destination.
- "per-mailbox Mail Views" was resolved as one global synchronized **Mail View** configuration whose contents are scoped by the selected mailbox.
- "launch Mail View" was resolved as transient local navigation state that resets to Unified Inbox and Important at the start of every application session.
- "all emails tab" was resolved as the scoped **All Messages Mail View**, labeled “All,” not the **All Mail** mailbox.
- "selected email" was resolved as a mailbox-scoped **Thread** conversation with every message expanded and ordered newest to oldest; thread-level actions target the newest eligible message, not a single-message-only reader.
- "generic provider threading" was resolved as provider conversation identity or RFC reply-header linkage, never subject-only grouping.
- "default sender" was resolved as a Profile-scoped **Default Sending Identity**, initially migrated from the **Default Sending Connection**, not the most recently used address.
- "reply sender" was resolved as the authorized receiving **Sending Identity**; an unavailable identity blocks Send instead of silently falling back.
- "provider folder mapping" was resolved as explicit **Mailbox Roles** from provider semantics, IMAP special-use markers, or user mapping, never localized folder-name guessing.
- "outbox" was resolved as the product-owned **Outbox** delivery queue, not the **Sent Mailbox**.
- "outbox retries" was resolved as automatic bounded retry for transient failures, user action for permanent failures, and immutable **Outgoing Delivery Attempts**.
- "delayed send" and "planned send" were resolved as one-time **Scheduled Send**, not the **Undo Send Window**, recurrence, or a provider-native timer.
- "remind me to send" was resolved as a **Send Reminder** attached to a Draft, not authorization for automatic delivery.
- "scheduled send timing" was resolved as best-effort delivery at or after an absolute selected instant, with user attention required after 24 hours, not an exact-time guarantee.
- "cross-device scheduled send" was resolved as an end-to-end encrypted Outbox commitment with one revision-bound **Scheduled Send Claim**, not independent device timers.
- "draft storage" was broadened to the 100 MB **Outgoing Content Store** shared by Drafts, Send Reminders, Scheduled Sends, and their authored assets.
- "pins" was resolved as product-owned Thread-level **Pins** synchronized across trusted devices, not message Pins, Gmail stars, or IMAP flags.
- "category" was resolved as **Synced Category**, not a provider folder or label.
- "category-provider mapping" was resolved as separate in v1, not provider-visible category sync.
- "synced across devices" was resolved as **Product Sync**, not iCloud sync.
- "privacy-focused backend sync" was resolved as **End-to-End Encrypted Product Sync**, not server-readable sync.
- "recovery mechanism" was resolved as **Recovery Key**, not password-only recovery or support-assisted decryption.
- "categorization" was resolved as **Message Category** assignment, not thread-level categorization.
- "category sync identity" was resolved as **Mailbox Connection** plus **Stable Provider Message Identity**, not local database IDs.
- "cannot be changed by the system" was resolved as **System Categorization** being immutable unless changed by a **User Override**.
- "historical categorization" was resolved as **New-Mail-Only Categorization** by default with optional **Historical Categorization Opt-In**.
- "categorize old emails" was resolved as **Bounded Historical Categorization**, not all-mail backfill.
- "custom categories" was resolved as coexistence of **System Categories** and multiple user-created **Custom Categories**.
- "invoices" was broadened to the **Orders** System Category, covering the purchase lifecycle rather than invoices alone.
- "promotions" was broadened to the **Newsletters & Promotions** System Category, covering subscribed newsletters as well as commercial marketing messages.
- "emails from people" was resolved as the **People** System Category for direct human correspondence, not a sender-name heuristic.
- "custom category definition" was resolved as a name plus optional **Category Description**.
- "AI input" was resolved as **Minimized Classification Input**, not full body text by default.
- "uncategorized" was resolved as **Uncategorized State**, not a category or separate historical-mail state.
- "learning from overrides" was resolved as **Future Learning Signal**, not retroactive recategorization.
- "category conflict resolution" was resolved as per-membership **Category Conflict Rule**: different Category changes merge, user actions beat system actions, and concurrent user removal beats addition.
- "email storage" was resolved as locally read **Durable Message Metadata** plus a **Bounded Encrypted Body Cache**, not permanent full-body or attachment storage.
- "initial mailbox sync" was resolved as **Initial Mailbox Availability** after the newest 50 messages, followed by **Historical Metadata Backfill** while body prefetch starts immediately without blocking mailbox use.
- "historical metadata scope" was resolved as the complete provider-visible mailbox history with resumable backfill, not a full historical body archive.
- "body prefetch" was resolved as recent Inbox and **Sent Mailbox** body text plus pinned bodies regardless of age, not Spam, Trash, attachments, or older unpinned bodies.
- "recent body prefetch" was resolved as the newest 500 messages combined across Inbox and **Sent Mailbox** from the last 30 days per **Mailbox Connection**, whichever boundary is reached first.
- "body-cache limit" was resolved as 500 MB per device with opened older, non-pinned prefetched, then pinned-body eviction priority; draft bodies remain separate.
- "push metadata" was resolved as **Minimal Push Metadata**, not server-side mailbox sync.
- "real-time mail" was resolved as **Best-Effort Background Freshness**, not guaranteed instant background delivery or backend-held mailbox credentials.
- "auto-refresh" was resolved as launch and foreground synchronization, provider signals, a five-minute active-app fallback poll, manual refresh, and locally observed mailbox views.
- "sync health" was resolved as visible per-connection **Mailbox Sync Status**, global refresh and last-success information, and non-blocking backfill progress.
- "push notifications" for the focused release was resolved as device-evaluated **New Mail Notifications**, with generic content by default and optional sender/subject previews.
- "notification fallback" was resolved as optional **Generic Notification Fallback**, not default behavior.
- "account sign-in" was resolved as **Product Sign-In**, distinct from **Mailbox Authorization** even when one onboarding journey obtains both grants.
- "backend-readable account data" was resolved as **Operational Account Data**, not user organization data or mailbox content.
- "notification rules" were resolved as encrypted user data, not backend-readable routing rules.
