# Private Email

This context describes the language for an Apple-first private email product that helps people manage email without sending message content to a server for AI processing.

## Language

**Apple-first private email client**:
An email client for iOS, iPadOS, and macOS where privacy-sensitive processing is expected to happen on the user's device.
_Avoid_: Cross-platform email client, webmail

**True email client**:
An email client that connects to mail providers directly and owns mailbox access, sync state, and message organization inside the product.
_Avoid_: Email assistant, Apple Mail extension

**Provider Mail Action**:
A user action that changes mailbox state through a mail provider's native capabilities.
_Avoid_: Product category action

**Pending Provider Action**:
A durable user-requested **Provider Mail Action** that has changed local presentation but still awaits provider confirmation.
_Avoid_: Outbox message, completed provider action

**Mail Provider**:
A service or protocol endpoint that supplies mailbox data to the product.
_Avoid_: Email backend, email source

**Mailbox Connection**:
An authenticated link between a **Product Account** and one provider mailbox account supplied by a **Mail Provider**; it may contain provider mailboxes such as folders or labels.
_Avoid_: Account, Product Account, provider account

**Provider Mailbox**:
A provider-owned folder, label, or equivalent mailbox container within one **Mailbox Connection** that may receive a **Mailbox Role**.
_Avoid_: Mailbox Connection, Unified Mailbox

**Stable Provider Mailbox Identity**:
A provider-issued immutable mailbox or account identifier; when a provider supplies none, the client uses its provider type, verified endpoint, and canonical authenticated mailbox identity and asks the user to repair rather than merge a mismatch.
_Avoid_: Display name, local database ID

**Stable Provider Connection Key**:
A deterministic, device-generated opaque key derived from the provider type and **Stable Provider Mailbox Identity** (and verified endpoint when needed), stored only inside the end-to-end encrypted **Mailbox Connection** definition. Trusted devices use it to converge concurrent additions of the same provider mailbox.
_Avoid_: Backend-readable email address, random local connection ID

**Mailbox Authorization**:
A device-local credential grant that lets one trusted device access a **Mailbox Connection**.
_Avoid_: Mailbox Connection, synced provider credential

**Default Sending Connection**:
The user-selected **Mailbox Connection** used by default for newly composed messages.
_Avoid_: Most recently used account, reply identity

**Remove Device Authorization**:
A device-scoped action that deletes local mailbox credentials and cached mail without removing the synchronized **Mailbox Connection**.
_Avoid_: Remove Mailbox Connection Everywhere

**Remove Mailbox Connection Everywhere**:
A product-account-scoped action that removes a **Mailbox Connection** and its product-owned state from every trusted device without deleting provider mail.
_Avoid_: Remove Device Authorization, delete provider mailbox

**Standards-Based Mailbox Connection**:
A **Mailbox Connection** that uses IMAP for mailbox access and synchronization and SMTP for outgoing mail delivery.
_Avoid_: IMAP-only account, read-only mailbox connection

**Full-Capability Mailbox Connection**:
A **Mailbox Connection** that provides the product's complete reading, organization, drafting, sending, and recovery action set.
_Avoid_: Legacy POP3 Connection, receive-only connection

**Secure Mail Transport**:
Encrypted provider communication using TLS 1.2 or newer with valid server identity before any mailbox authentication occurs.
_Avoid_: Plaintext mail access, invalid-certificate exception

**Mailbox Service Discovery**:
Device-side discovery of provider endpoints through email-service DNS records or a bundled reviewed catalog, with user-reviewed manual configuration as fallback.
_Avoid_: Backend account discovery, silent server guessing

**On-Premises Exchange Connection**:
A **Mailbox Connection** to an organization-hosted Exchange server through Exchange Web Services.
_Avoid_: Exchange Online EWS connection, Microsoft 365 EWS connection

**Legacy POP3 Connection**:
A limited **Mailbox Connection** that retrieves from one POP3 maildrop, sends through SMTP, and keeps mailbox organization as product-owned state.
_Avoid_: Standards-Based Mailbox Connection, synchronized server mailbox

**Unified Mailbox**:
A product-owned view that aggregates messages with the same mailbox role across all of a user's **Mailbox Connections**.
_Avoid_: Unified folder, mailbox account

**Mailbox Role**:
A provider-independent meaning such as Inbox, Sent, Drafts, Spam, Trash, or Archive assigned to a provider mailbox or label.
_Avoid_: Folder name, localized-name inference

**All Mail**:
A product-local aggregate of every message except Spam and Trash across all **Mailbox Connections**, available even when a provider has no native all-mail mailbox.
_Avoid_: Required provider folder, Gmail-only mailbox

**Sent Mailbox**:
A mailbox containing messages whose delivery has completed successfully; its unified form aggregates sent messages across **Mailbox Connections**.
_Avoid_: Outbox, sending queue

**Outbox**:
A product-owned queue containing outgoing messages that are pending, retrying, or failed rather than confirmed as sent.
_Avoid_: Sent Mailbox, sent folder

**Outgoing Delivery Attempt**:
An immutable attempt to send one Outbox message through a selected **Mailbox Connection**.
_Avoid_: Draft edit, Provider Mail Action

**Pin**:
A product-owned marker that keeps a message in the unified pinned-message view across trusted devices without changing provider flags.
_Avoid_: Gmail star, IMAP flag, provider pin

**Gmail-first provider support**:
The provider strategy where multiple Gmail **Mailbox Connections** precede generic IMAP and SMTP, Microsoft Graph, POP3 and Exchange Web Services, while JMAP is deferred.
_Avoid_: Provider-agnostic v1

**Category**:
A user-defined grouping used by the product to organize messages independently of provider folders and labels.
_Avoid_: Folder, Gmail label, Outlook category

**System Category**:
A product-provided **Category** available without user setup.
_Avoid_: Default folder, provider label

**Custom Category**:
A user-created **Category** for organizing messages according to the user's own needs.
_Avoid_: Custom folder, provider label

**Category Description**:
Optional user-written guidance that explains when a **Custom Category** should apply.
_Avoid_: Prompt, rule

**Message Category**:
A category assigned to an individual message, such as promotions, invites, invoices, or flights.
_Avoid_: Thread category, folder

**Stable Provider Message Identity**:
A provider-specific message identity used to match the same message across devices. Gmail uses its immutable message resource ID; Microsoft Graph connections require immutable IDs; IMAP uses its immutable provider-mailbox identity plus UIDVALIDITY and UID; POP3 connections require UIDL; and Exchange uses its provider item identity. A provider that cannot supply the required stable identity is not eligible for a synchronized Mailbox Connection. Provider adapters retain a verified repair mapping for provider-issued identity changes such as moves; if repair is ambiguous or unavailable, they create a distinct product record rather than applying product state to the wrong message.
_Avoid_: Local database ID, backend message ID

**Uncategorized State**:
The state of a message when no **Message Category** has been assigned, including historical mail that is not automatically categorized.
_Avoid_: Uncategorized category, forced category

**Thread**:
A group of related messages within one **Mailbox Connection**, shown together as a conversation.
_Avoid_: Category target

**System Categorization**:
Automatic assignment of a **Message Category** by the product.
_Avoid_: Manual category

**New-Mail-Only Categorization**:
The rule that **System Categorization** applies only to messages received after their **Mailbox Connection** is first added to the product.
_Avoid_: Historical backfill

**Historical Categorization Opt-In**:
A user choice that allows old mail to be categorized during onboarding or later.
_Avoid_: Automatic historical backfill

**Bounded Historical Categorization**:
Historical categorization limited by user-selected scope such as date range, mailbox, label, or category target.
_Avoid_: All-mail backfill

**Minimized Classification Input**:
The least amount of message data needed for **System Categorization**, starting with metadata, subject, snippet, and headers before body text.
_Avoid_: Full-message classification by default

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
Locally encrypted storage for prefetched recent body text and opened older body text, excluding attachments and constrained by eviction controls.
_Avoid_: On-demand-only body cache, permanent body store, attachment archive

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
User-owned preference that controls which categorized messages can produce visible notifications.
_Avoid_: Backend routing rule

**Generic Notification Fallback**:
An optional user setting that allows a visible new-mail notification when category-aware notification processing cannot finish in time.
_Avoid_: Default generic notification

**User Override**:
A category change made by the user after **System Categorization**.
_Avoid_: Recategorization

**Future Learning Signal**:
Information from a **User Override** that can improve categorization of future messages without changing already categorized messages.
_Avoid_: Retroactive recategorization

**Category Conflict Rule**:
The rule for resolving competing category assignments across trusted devices.
_Avoid_: Last-write-wins

**Synced Category**:
A **Category** that is available across the user's Apple devices without becoming provider-visible mailbox organization.
_Avoid_: Local-only category, provider label

**Product Account**:
An account owned by the product that identifies a user independently of their mail provider and Apple account.
_Avoid_: iCloud account, Gmail account, mailbox account

**Apple-First Sign-In**:
The Product Account sign-in strategy where Sign in with Apple is supported before email magic link.
_Avoid_: Password-first account

**Operational Account Data**:
Backend-readable account data needed to run identity, billing, device routing, and encrypted sync operations.
_Avoid_: User organization data, mailbox content

**Product Sync**:
Synchronization of product-owned user data across devices through the product's backend.
_Avoid_: iCloud sync, provider sync

**End-to-End Encrypted Product Sync**:
**Product Sync** where synced product data is readable only by the user's trusted devices.
_Avoid_: Server-readable sync, plaintext sync

**Recovery Key**:
A user-held secret that can restore access to encrypted product data when no trusted device is available.
_Avoid_: Password reset, support recovery

## Relationships

- An **Apple-first private email client** runs on iOS, iPadOS, and macOS
- A **True email client** is responsible for mailbox access and message organization
- A **True email client** connects to one or more **Mail Providers**
- A **Product Account** may own multiple **Mailbox Connections**
- A **Mailbox Connection** links one **Product Account** to one provider mailbox account supplied by a **Mail Provider** and contains that account's **Provider Mailboxes**
- A **Product Account** may contain only one **Mailbox Connection** for a **Stable Provider Connection Key**
- Re-adding an existing provider mailbox authorizes or repairs its **Mailbox Connection** instead of creating a duplicate; after synchronization, trusted devices group equal **Stable Provider Connection Keys**, keep the lexicographically lowest connection identifier, and migrate product-owned pins, categories, pending actions, and Outbox attempts to it before deleting duplicate connection records
- A **Mailbox Connection** definition, including its reviewed non-secret address, username, and endpoint settings, synchronizes end-to-end encrypted across trusted devices without provider credentials
- Each trusted device needs its own **Mailbox Authorization** before it can access a synchronized **Mailbox Connection**
- **Mailbox Authorization** prefers provider OAuth but may use a password or app-specific password over **Secure Mail Transport**
- Passwords, app-specific passwords, and OAuth refresh tokens remain in the current device's Keychain
- **Remove Device Authorization** affects only the current device and preserves the synchronized **Mailbox Connection**
- **Remove Mailbox Connection Everywhere** removes synchronized connection and product-owned state from all trusted devices but never deletes provider mail
- A trusted device that receives **Remove Mailbox Connection Everywhere** purges its **Mailbox Authorization** and cached mail for that connection before any later provider access or synchronization
- After wake or reconnect, a trusted device processes synchronized connection-removal tombstones before it resumes any queued **Provider Mail Action** or **Outgoing Delivery Attempt** for that connection
- A **Standards-Based Mailbox Connection** requires both IMAP and SMTP before it is considered complete
- Gmail, **Standards-Based Mailbox Connections**, Microsoft Graph, and **On-Premises Exchange Connections** are **Full-Capability Mailbox Connections**
- A **Full-Capability Mailbox Connection** supports read state, archive, move, delete and restore, spam state, compose, reply, reply all, forward, drafts, and Outbox recovery
- Pin and unpin are product-owned actions available across full and reduced connection types
- IMAP, SMTP, POP3, and Exchange Web Services require **Secure Mail Transport**
- **Secure Mail Transport** prefers implicit TLS, permits STARTTLS only before authentication, and has no invalid-certificate override
- **Mailbox Service Discovery** happens on the device and never uploads an email address or server configuration to the product backend
- A user reviews discovered endpoints before connection and may enter host, port, username, and security settings manually when discovery fails
- Exchange Online and Microsoft 365 use Microsoft Graph, while an **On-Premises Exchange Connection** uses Exchange Web Services
- A **Legacy POP3 Connection** leaves downloaded messages on the server by default
- A **Legacy POP3 Connection** does not promise server-synchronized folders, moves, flags, or real-time delivery
- A **Legacy POP3 Connection** does not support server-side body search; it may search locally retained metadata, while body search remains unavailable unless the matching body is already available in the **Bounded Encrypted Body Cache**
- A **Unified Mailbox** aggregates a mailbox role across all **Mailbox Connections**
- The permanent **Unified Mailboxes** are Inbox, Pins, Drafts, **Sent Mailbox**, Archive, All Mail, Spam, and Trash
- **All Mail** is a product-local aggregate of every non-Spam, non-Trash message across all **Mailbox Connections**, not a required provider mailbox role
- **Outbox** is a conditional unified item rather than a permanent mailbox
- Provider-specific custom folders and labels remain under their **Mailbox Connection** and do not gain synthetic unified views
- Provider-native semantics or IMAP special-use markers assign a **Mailbox Role** when they are unambiguous
- A user explicitly maps any required **Mailbox Role** that a provider does not identify unambiguously; if no provider mailbox can supply a required role, the client offers to create one when the provider permits it, otherwise the connection remains incomplete for actions requiring that role and has no product-local fallback
- **Mailbox Roles** are never inferred from localized folder names and user mappings may be changed later
- Changing a **Mailbox Role** mapping reclassifies existing local metadata and applies to future synchronization; the prior mapping is retained until the new mapping completes and may be restored if the change fails
- When a **Mailbox Role** mapping changes, every pending **Provider Mail Action** whose target or meaning changed is cancelled until the user reconfirms it against the new mapping
- A user may select either a **Unified Mailbox** or a mailbox within one **Mailbox Connection** to scope the messages being viewed
- A **Unified Mailbox** interleaves mailbox-scoped **Threads** by latest message time rather than grouping them by account
- Every thread in a **Unified Mailbox** visibly identifies its source **Mailbox Connection**
- Background synchronization preserves the selected **Thread** when newer threads enter the list
- The unified **Sent Mailbox** is always available
- After SMTP accepts a message for a **Standards-Based Mailbox Connection**, the client appends a verified copy to its mapped Sent role; if that append cannot be confirmed, it retries or reconciles only the sent-copy operation, visibly marks the copy as pending, and never resends the delivered message
- The **Outbox** appears only while it contains a pending, retrying, or failed outgoing message
- Transiently failed **Outgoing Delivery Attempts** retry automatically with bounded exponential backoff
- Permanently failed **Outgoing Delivery Attempts** stop until the user resolves authentication, policy, recipient, or message problems
- Pending and failed Outbox messages remain editable and cancellable until an **Outgoing Delivery Attempt** has been handed to its provider; an in-flight attempt must first reach a terminal state
- Editing an eligible Outbox message creates a new **Outgoing Delivery Attempt** rather than mutating an attempt already in flight
- A **Pin** is protected by **End-to-End Encrypted Product Sync**, is keyed by its **Mailbox Connection** and **Stable Provider Message Identity**, and remains independent of provider-visible flags
- Pinned messages from all **Mailbox Connections** appear together in the unified pinned-message view
- A **True email client** supports **Provider Mail Actions**
- An offline **Provider Mail Action** becomes a **Pending Provider Action** and updates local presentation optimistically
- **Pending Provider Actions** are ordered per **Mailbox Connection** and retried when connectivity returns
- A permanently rejected **Pending Provider Action** restores provider-derived state, replays later pending actions in order, and produces a visible failure without overwriting newer optimistic changes
- Each **Pending Provider Action** has a stable idempotency key and immutable attempt record; an ambiguous provider response is reconciled before retrying so the provider mutation is not duplicated
- For an ambiguous IMAP move, archive, or copy, the client retries only after it verifies the source-to-target mapping; otherwise it stops the action for user resolution rather than replaying it
- Product-owned actions such as **Pin** do not wait for a mail provider and synchronize independently
- A bulk selection may span multiple **Mailbox Connections** but exposes only actions supported by every selected connection
- Cross-connection bulk actions execute as per-connection batches and preserve successful batches when another connection fails
- **Gmail-first provider support** orders provider delivery as multiple Gmail **Mailbox Connections**, generic IMAP and SMTP, Microsoft Graph, then POP3 and Exchange Web Services; JMAP is deferred
- A **Synced Category** belongs to the product, not to a **Mail Provider**
- A **Provider Mail Action** may change provider state, but a **Message Category** does not
- A **Product Account** identifies the user for **Product Sync**
- **Product Sync** shares **Synced Categories** across the user's devices
- **End-to-End Encrypted Product Sync** prevents the product backend from reading **Synced Categories**
- A **Recovery Key** can restore access to data protected by **End-to-End Encrypted Product Sync**
- A **Message Category** is assigned to an individual message, not to a **Thread**
- A **Message Category** syncs across devices by its **Mailbox Connection** and **Stable Provider Message Identity**
- A **Thread** groups related messages without being the categorization target
- A **Thread** never spans multiple **Mailbox Connections**, including when shown in a **Unified Mailbox**
- A **Thread** uses a reliable provider conversation identity when available, otherwise RFC message and reply identifiers
- Subject similarity alone never combines messages into a **Thread**, and messages without reliable linkage remain separate
- Selecting a **Thread** opens its conversation rather than only its latest message
- The conversation reader expands the latest message and keeps older messages available to expand
- Replies from a **Thread** use that thread's **Mailbox Connection** identity
- Replies and forwards default to their source **Thread** identity rather than the **Default Sending Connection**
- If a source **Thread** connection cannot send on the current device, the user must authorize it or explicitly select another sender; the product never silently substitutes an identity
- A new message defaults to the **Default Sending Connection** and always exposes its sending identity
- The **Default Sending Connection** synchronizes across trusted devices without mailbox credentials
- If the **Default Sending Connection** cannot send on the current device, the user must authorize it or explicitly select another sender
- The product never silently substitutes a different sending identity
- Unauthorized or receive-only **Mailbox Connections** remain visible but cannot be selected for sending
- **System Categorization** must not change an existing **Message Category**, whether it is a **System Category** or **Custom Category**
- A **User Override** may change an existing **Message Category**
- **New-Mail-Only Categorization** excludes mail received before its **Mailbox Connection** was added from automatic categorization
- **Historical Categorization Opt-In** permits categorization of old mail when the user chooses it
- **Bounded Historical Categorization** limits **Historical Categorization Opt-In** to a user-selected scope
- A **Category** may be a **System Category** or a **Custom Category**
- A **Custom Category** may have a **Category Description**
- **System Categorization** uses **Minimized Classification Input** before inspecting message body text
- A message in **Uncategorized State** has no **Message Category**
- **System Categorization** may assign a **Message Category** to a message in **Uncategorized State**
- Historical mail remains in **Uncategorized State** under **New-Mail-Only Categorization**
- A **User Override** may become a **Future Learning Signal**
- A **Future Learning Signal** must not change existing **Message Categories**
- The **Category Conflict Rule** gives user actions priority over system actions and otherwise keeps the first assignment
- **Durable Message Metadata** is retained separately from the **Bounded Encrypted Body Cache**
- **Durable Message Metadata** is read locally before mailbox synchronization updates it
- **Initial Mailbox Availability** requires the newest 50 message metadata, or all provider-visible messages when fewer exist, and does not wait for full history
- **Historical Metadata Backfill** continues after the mailbox becomes usable and reports progress separately
- **Historical Metadata Backfill** pauses under low storage, low power, or network loss and resumes when conditions permit
- Completing **Historical Metadata Backfill** does not require retaining historical message bodies
- Body prefetch begins after **Initial Mailbox Availability** rather than delaying the newest message list
- The **Bounded Encrypted Body Cache** prefetches body text for a recent working set without prefetching attachments
- For each **Mailbox Connection**, the prefetched recent working set contains at most 500 distinct messages combined across Inbox and **Sent Mailbox**, selected at one synchronization reference instant from messages whose applicable timestamp falls from that instant minus 30 days through that instant, inclusive, ordered by newest applicable timestamp first; duplicate appearances use the later applicable timestamp, and **Stable Provider Message Identity** is the deterministic tie-breaker
- Recent and pinned prefetched bodies are admitted by evicting only eligible bodies outside the combined selected-recent and pinned protected set; selected-recent and pinned bodies never evict one another during that selection, and bodies refused admission remain on demand until a later synchronization finds space
- Pinned message bodies are eligible for prefetch regardless of the 30-day and 500-message cutoffs, subject to that combined protected-set admission rule; otherwise their metadata remains pinned and the body is fetched on demand until cache space becomes available
- Spam, Trash, attachments, and older unpinned message bodies remain on-demand; Spam and Trash exclusion overrides a **Pin** for body prefetch
- Draft body content remains available offline as product-authored local data in a separately encrypted 100 MB device-wide draft store and synchronizes through **End-to-End Encrypted Product Sync** to trusted devices; drafts are never evicted automatically, and a full store prevents saving additional draft content until the user removes or shortens a draft. Incoming draft content that would exceed the local limit remains encrypted in Product Sync and is marked pending local storage rather than discarded; its body is admitted after space is freed. When trusted devices edit the same draft from the same synchronized revision while offline, synchronization preserves both bodies: the later upload remains the original draft and the other becomes a user-visible conflicted draft copy; neither body is silently overwritten
- The **Bounded Encrypted Body Cache** has a 500 MB device-wide limit
- Cache eviction removes eligible opened older non-pinned bodies first, then eligible non-pinned prefetched bodies, then least-recently-read pinned bodies as a last resort; bodies in the current selected-recent and pinned protected set are not eligible until a later selection no longer protects them
- Evicting a pinned body preserves its **Pin** and fetches the body again on demand
- Draft bodies are stored separately and do not count against the body-cache limit, but are constrained by the separate draft-store limit
- **System Categorization** may use the **Bounded Encrypted Body Cache** when **Minimized Classification Input** is insufficient
- **Minimal Push Metadata** may route a mailbox-change wakeup without exposing message bodies, provider tokens, categories, or classification data; Gmail's provider-supplied email address and history identifier are permitted only as transient push-routing inputs, must not be persisted or included in application logs, and must be discarded after the wakeup is routed
- **Best-Effort Background Freshness** uses provider push where available, active IMAP connections, system-scheduled background refresh, and foreground synchronization
- Every authorized **Mailbox Connection** synchronizes on app launch and foreground activation
- While the app remains active, provider signals are supplemented by a five-minute fallback poll and manual refresh
- Mailbox views observe local **Durable Message Metadata** so synchronized changes appear without reopening the view
- Each **Mailbox Connection** exposes **Mailbox Sync Status** without blocking cached mail use
- Manual refresh and the last successful synchronization are visible globally, while **Historical Metadata Backfill** progress remains in connection details
- Missed or delayed background changes are reconciled when a trusted device next wakes or becomes active
- **Best-Effort Background Freshness** does not permit the backend to hold **Mailbox Authorization** or synchronize mail itself
- A **Category-Aware Notification** depends on local **System Categorization**
- A **Generic Notification Fallback** is optional and not the default notification behavior
- **Apple-First Sign-In** identifies a **Product Account**
- The backend may read **Operational Account Data** but not user organization data or mailbox content
- A **Notification Rule** is encrypted user data and is evaluated on trusted devices

## Example dialogue

> **Dev:** "Should the first version support Android?"
> **Domain expert:** "No — this is an **Apple-first private email client**, so iOS, iPadOS, and macOS come first."
> **Dev:** "Can we rely on Apple Mail as the source of messages?"
> **Domain expert:** "No — this is a **True email client**, so it connects to providers directly."
> **Dev:** "Can users archive, delete, reply, and use provider-native mailbox actions?"
> **Domain expert:** "Yes — a **True email client** supports **Provider Mail Actions**."
> **Dev:** "Should the provider layer be fully neutral from day one?"
> **Domain expert:** "No — use **Gmail-first provider support**: multiple Gmail connections first, then IMAP and SMTP, Microsoft Graph, POP3 and Exchange Web Services; defer JMAP."
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
> **Dev:** "Does pinning a Gmail message add a star?"
> **Domain expert:** "No — a **Pin** is product-owned, syncs across trusted devices, and does not change provider flags."
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
> **Domain expert:** "No — assign a **Message Category** to each message, while the **Thread** only groups related messages."
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
> **Domain expert:** "Use the **Category Conflict Rule**: user action beats system action, otherwise first assignment wins."
> **Dev:** "Should the app permanently store every email body?"
> **Domain expert:** "No — store **Durable Message Metadata** and categorization, while using a **Bounded Encrypted Body Cache** for recent and previously opened body text."
> **Dev:** "Which message bodies should be prefetched?"
> **Domain expert:** "At each synchronization reference instant, select the newest up to 500 distinct Inbox and **Sent Mailbox** bodies from the preceding 30 days. Recent and pinned bodies may reclaim only eligible bodies outside their combined protected set, so they never evict one another during that selection; keep Spam, Trash, attachments, and older unpinned bodies on-demand, with Spam and Trash excluded even when pinned."
> **Dev:** "Can the backend participate in push without holding mail provider tokens?"
> **Domain expert:** "Yes — it may use **Minimal Push Metadata** to wake trusted devices, but devices fetch mail themselves."
> **Dev:** "Can the app guarantee instant background delivery for every provider?"
> **Domain expert:** "No — **Best-Effort Background Freshness** preserves device-local mailbox authorization and reconciles delayed changes on the next available wake or foreground activation."
> **Dev:** "Should users get generic new-mail alerts?"
> **Domain expert:** "No — prefer **Category-Aware Notifications** based on local categorization and user notification rules."
> **Dev:** "If category-aware processing cannot finish in the background, should the app still show a new-mail alert?"
> **Domain expert:** "No by default — only show one when the user enables **Generic Notification Fallback**."
> **Dev:** "Should account sign-in start with passwords?"
> **Domain expert:** "No — use **Apple-First Sign-In**, then add email magic link later if needed."
> **Dev:** "Can the backend read category names for support?"
> **Domain expert:** "No — the backend may only read **Operational Account Data**."
> **Dev:** "Can the backend read notification preferences to optimize routing?"
> **Domain expert:** "No — a **Notification Rule** is encrypted user data and devices decide whether to show notifications."

## Flagged ambiguities

- "email app" was resolved as **Apple-first private email client**, not a cross-platform email client.
- "email app" was resolved as **True email client**, not an assistant layer on top of Apple Mail.
- "main actions" was resolved as **Provider Mail Actions**, not product category actions.
- "offline mail actions" was resolved as optimistic local changes backed by durable **Pending Provider Actions**, not silent failure or online-only interaction.
- "cross-account bulk actions" was resolved as capability-intersection actions with per-connection execution and partial-success reporting, not an all-or-nothing transaction.
- "multiple accounts" was resolved as multiple **Mailbox Connections** owned by one **Product Account**, not multiple product sign-ins.
- "duplicate account connection" was resolved as authorization or repair of the existing **Mailbox Connection**, not a second connection for the same **Stable Provider Mailbox Identity**.
- "mailbox credential sync" was resolved as synchronized non-secret **Mailbox Connections** with device-local **Mailbox Authorization**, not synchronized provider credentials.
- "generic provider authentication" was resolved as preferred OAuth with device-Keychain passwords or app passwords permitted over **Secure Mail Transport**; client certificates and enterprise SSO are deferred.
- "disconnect account" was split into **Remove Device Authorization** and **Remove Mailbox Connection Everywhere**, with distinct local and cross-device data scopes.
- "provider rollout" was resolved as multiple Gmail **Mailbox Connections**, generic IMAP and SMTP, Microsoft Graph, then POP3 and Exchange Web Services; JMAP is deferred.
- "Exchange Web Services support" was resolved as **On-Premises Exchange Connections** only; Exchange Online and Microsoft 365 use Microsoft Graph.
- "POP3 support" was resolved as a limited **Legacy POP3 Connection** using POP3 and SMTP with product-owned organization, not an IMAP-equivalent synchronized mailbox.
- "IMAP support" was resolved as a complete **Standards-Based Mailbox Connection** using IMAP and SMTP, not read-only mailbox access.
- "provider action parity" was resolved as the **Full-Capability Mailbox Connection** contract for Gmail, IMAP and SMTP, Microsoft Graph, and EWS; POP3 retains its reduced contract.
- "generic mail transport security" was resolved as **Secure Mail Transport** with TLS 1.2 or newer and valid server identity, not plaintext or user-approved invalid certificates.
- "generic account setup" was resolved as device-side **Mailbox Service Discovery** with user review and manual fallback, not backend-assisted or silent endpoint guessing.
- "unified inboxes" was resolved as **Unified Mailboxes** shown alongside the mailboxes belonging to each **Mailbox Connection**, not provider folders shared between providers.
- "unified navigation" was resolved as permanent Inbox, Pins, Drafts, Sent, Archive, All Mail, Spam, and Trash; conditional **Outbox**; and connection-scoped provider folders and labels.
- "unified message list" was resolved as one time-ordered thread list with visible Mailbox Connection identity and stable selection, not account-grouped sections.
- "selected email" was resolved as a mailbox-scoped **Thread** conversation with the latest message expanded, not a single-message-only reader.
- "generic provider threading" was resolved as provider conversation identity or RFC reply-header linkage, never subject-only grouping.
- "default sender" was resolved as a user-selected **Default Sending Connection**, not the most recently used connection; replies and forwards retain their source thread identity.
- "unavailable default sender" was resolved as an authorization or explicit sender-choice prompt, not silent fallback to another Mailbox Connection.
- "provider folder mapping" was resolved as explicit **Mailbox Roles** from provider semantics, IMAP special-use markers, or user mapping, never localized folder-name guessing.
- "outbox" was resolved as the product-owned **Outbox** delivery queue, not the **Sent Mailbox**.
- "outbox retries" was resolved as automatic bounded retry for transient failures, user action for permanent failures, and immutable **Outgoing Delivery Attempts**.
- "pins" was resolved as product-owned **Pins** synchronized across trusted devices, not Gmail stars or IMAP flags.
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
- "custom categories" was resolved as coexistence of **System Categories** and **Custom Categories**.
- "custom category definition" was resolved as a name plus optional **Category Description**.
- "AI input" was resolved as **Minimized Classification Input**, not full body text by default.
- "uncategorized" was resolved as **Uncategorized State**, not a category or separate historical-mail state.
- "learning from overrides" was resolved as **Future Learning Signal**, not retroactive recategorization.
- "category conflict resolution" was resolved as **Category Conflict Rule**, not last-write-wins.
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
- "push notifications" was resolved as **Category-Aware Notifications**, not generic new-mail notifications.
- "notification fallback" was resolved as optional **Generic Notification Fallback**, not default behavior.
- "account sign-in" was resolved as **Apple-First Sign-In**, not password-first account creation.
- "backend-readable account data" was resolved as **Operational Account Data**, not user organization data or mailbox content.
- "notification rules" were resolved as encrypted user data, not backend-readable routing rules.
