# Private Email

This context describes the language for an Apple-first private email product that helps people manage email without sending message content to a server for AI processing.

## Language

**Apple-first private email client**:
An email client for iOS, iPadOS, and macOS where privacy-sensitive processing is expected to happen on the user's device.
_Avoid_: Cross-platform email client, webmail

**On-Device Mail Assistance**:
Explicitly requested help for composing, responding to, understanding, or transforming mail through Apple system models on a trusted device, with no cloud or product-backend model fallback.
_Avoid_: Email assistant, background AI processing, cloud inference

**Assistance Context**:
The size-bounded, already-local Draft, selection, recipient-display, and Thread text explicitly admitted to one On-Device Mail Assistance operation. It excludes provider fetches, attachments, Inline Images, Remote Message Content, Contacts, Calendar data, and unrelated correspondence.
_Avoid_: mailbox context, account history, implicit retrieval

**Assistance Preview**:
Ephemeral generated or transformed content that remains separate from provider mail and saved Draft content until explicit acceptance and becomes unusable when its Mail Profile or source input revision changes.
_Avoid_: generated Draft, automatic edit, model memory

**True email client**:
An email client that connects to mail providers directly and owns mailbox access, sync state, and message organization inside the product.
_Avoid_: Email assistant, Apple Mail extension

**Provider Mail Action**:
A user action that changes mailbox state through a mail provider's native capabilities.
_Avoid_: Product category action

**Pending Provider Action**:
A durable user-requested **Provider Mail Action** that has changed local presentation but still awaits provider confirmation.
_Avoid_: Outbox message, completed provider action

**Blocked Sender**:
An exact normalized sender email address whose future arriving messages are moved recoverably to the Mail Provider's Trash on each trusted device that can mutate that Mailbox Connection. The synchronized preference does not retroactively move existing mail, infer aliases, or permanently erase messages.
_Avoid_: Display sender name, domain block, spam report

**Mail Provider**:
A service or protocol endpoint that supplies mailbox data to the product.
_Avoid_: Email backend, email source

**Approved Mail Engine Dependency**:
An exact-pinned third-party IMAP/SMTP engine admitted behind the product-owned Mail Engine boundary after deterministic qualification. Dependency approval does not certify any external Mail Provider or enable Standards-Based Mailbox Connections in an externally distributed release.
_Avoid_: Certified provider, universally compatible mail engine

**Experimental Standards-Based Mail**:
The release-gated IMAP/SMTP capability backed by the **Approved Mail Engine Dependency** while live-provider certification remains incomplete.
_Avoid_: Experimental dependency, certified provider support

**Local Mail Test Environment**:
A disposable, developer-controlled mail system used to exercise the product against realistic mailbox behavior without contacting an external **Mail Provider**.
_Avoid_: Mock mailbox, production provider

**Provider Test Mailbox**:
A non-production mailbox hosted by a real **Mail Provider** and reserved for provider-compatibility testing.
_Avoid_: Personal mailbox, user mailbox

**Provider Test Tenant**:
An organization-controlled, synthetic-only provider domain containing **Provider Test Mailboxes** and isolated from personal and production identities.
_Avoid_: Production tenant, personal provider account

**Provider Test Project**:
An isolated provider-platform project whose authorization, API quotas, event routes, and credentials exist only to support compatibility testing against a **Provider Test Tenant**.
_Avoid_: Production provider project, shared provider credentials

**Mailbox Scenario**:
A named, repeatable arrangement of messages, mailboxes, and mailbox state that local and provider test environments can instantiate with explicit capability-specific expectations.
_Avoid_: Test email, ad hoc fixture

**Synthetic Test Message**:
A standards-valid test message whose addresses, content, and assets were created for testing and do not derive from personal or production mail.
_Avoid_: Anonymized production email, copied personal email

**Core Mail Loop**:
The everyday sequence in which a person receives, synchronizes, reads, organizes, composes, sends, and replies to mail while observing the resulting mailbox state.
_Avoid_: Seeded inbox rendering, provider qualification

**Mail Test Run**:
An isolated execution of one **Mailbox Scenario** in a fresh **Local Mail Test Environment**, owned by one automated test or agent and discarded afterward.
_Avoid_: Shared test mailbox, persistent sandbox

**Provider Compatibility Run**:
A serialized execution of a **Mailbox Scenario** against a **Provider Test Tenant** and **Provider Test Project** through protected automation that does not expose reusable provider credentials.
_Avoid_: Mail Test Run, personal-account testing

**Manual Mail Sandbox**:
A persistent **Local Mail Test Environment** reserved for human exploratory testing and kept separate from automated **Mail Test Runs**.
_Avoid_: Automated test environment, shared agent mailbox

**Mail Test Harness**:
The product-owned interface through which humans and automation create, seed, observe, reset, and destroy test mail environments.
_Avoid_: Mail-server administration interface, ad hoc test script

**Mail Test Device**:
A harness-owned non-production app runtime whose app data, credentials, and trust state are isolated for one **Mail Test Run** or **Manual Mail Sandbox**.
_Avoid_: Personal simulator, shared development device

**Test Product Account**:
An isolated non-production **Product Account** identity used only within a **Mail Test Run** and representing neither a real person nor a backend account.
_Avoid_: Personal Product Account, shared test user

**Mail Test Bootstrap**:
The minimum startup configuration that lets a test-only build enter its **Test Product Account** and authorize the mailbox assigned to its **Mail Test Run**.
_Avoid_: In-app test control API, fixture loader

**Mail Test Evidence**:
A redacted, machine-readable record of a **Mail Test Run** or **Provider Compatibility Run** and the app-visible and server-visible outcomes needed to verify or diagnose it.
_Avoid_: Unstructured test log, credential-bearing artifact

**Mail Test Ownership Record**:
A run-bound record that identifies the exact processes, devices, endpoints, and generated state the **Mail Test Harness** is permitted to mutate or destroy.
_Avoid_: Resource-name match, global cleanup rule

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

**Delete Product Account**:
An immediate, irreversible action that deletes the user's product identity, operational data, encrypted Product Sync data, and push routes without deleting provider mail.
_Avoid_: Remove Mailbox Connection Everywhere, delete provider mailbox, recoverable deactivation

**Standards-Based Mailbox Connection**:
A **Mailbox Connection** that uses IMAP for mailbox access and synchronization and SMTP for outgoing mail delivery.
_Avoid_: IMAP-only account, read-only mailbox connection

**Full-Capability Mailbox Connection**:
A **Mailbox Connection** that provides the product's complete reading, organization, drafting, sending, and recovery action set.
_Avoid_: Legacy POP3 Connection, receive-only connection

**Message Read State**:
The provider-visible read or unread state of a message within a **Mailbox Connection**.
_Avoid_: Read Receipt, local viewing history

**Read Receipt**:
An acknowledgement that may tell a sender their message was opened, kept separate from the message's **Message Read State**.
_Avoid_: Read status, unread indicator

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

**Mail View**:
A user-selectable filter within the currently selected mailbox scope that narrows the **Threads** shown without changing mailbox membership or **Message Categories**.
_Avoid_: Category, Mailbox, bottom tab

**All Messages Mail View**:
The permanent **Mail View** that shows every Thread in the selected mailbox scope and is labeled “All” in compact navigation.
_Avoid_: All Mail, All emails

**Sent Mailbox**:
A mailbox containing messages whose delivery has completed successfully; its unified form aggregates sent messages across **Mailbox Connections**.
_Avoid_: Outbox, sending queue

**Outbox**:
A product-owned queue containing outgoing messages that are pending, retrying, or failed rather than confirmed as sent.
_Avoid_: Sent Mailbox, sent folder

**Draft**:
An editable, unsent outgoing message retained by the product until it is explicitly discarded or durably admitted to the **Outbox**.
_Avoid_: Outbox message, temporary composer

**Semantic Message Document**:
The editable message-body representation shared by Markdown input shortcuts, formatting controls, context actions, Draft synchronization, and outgoing format generation.
_Avoid_: Stored Markdown, raw HTML draft

**Outgoing Delivery Attempt**:
An immutable attempt to send one Outbox message through a selected **Mailbox Connection**.
_Avoid_: Draft edit, Provider Mail Action

**Undo Send Window**:
A user-selected delay before an **Outgoing Delivery Attempt** is handed to its provider, during which the Outbox message remains cancellable.
_Avoid_: Provider recall, retract delivered message

**Scheduled Send**:
A one-time commitment to deliver an outgoing message at or after a user-selected future time.
_Avoid_: Delayed send, planned send, recurring send, Undo Send Window

**Send Reminder**:
A one-time future prompt attached to a **Draft** that does not authorize the product to deliver the message.
_Avoid_: Scheduled Send, automatic send

**Scheduled Send Claim**:
A revision-bound right held by one eligible **Trusted Device** to advance a **Scheduled Send** toward provider handoff.
_Avoid_: Unfenced timer, renewable delivery lease

**Scheduled Delivery Authorization**:
A revocable device-bound authorization that permits a compatible **Trusted Device** to claim and revalidate Scheduled Send delivery without interactive sign-in.
_Avoid_: Mailbox Authorization, provider credential, backend delivery credential

**Pin**:
A product-owned marker that keeps a **Thread** in the unified pinned view across trusted devices without changing provider flags.
_Avoid_: Message pin, Gmail star, IMAP flag, provider pin

**Muted Thread**:
A Profile-scoped, product-owned suppression state for a **Thread** that prevents notifications and proactive suggestions without hiding mail, changing unread state, or changing provider mail.
_Avoid_: Provider mute, hidden Thread, notification rule

**Gmail-first provider support**:
The provider strategy where multiple Gmail **Mailbox Connections** precede generic IMAP and SMTP, Microsoft Graph, POP3 and Exchange Web Services, while JMAP is deferred.
_Avoid_: Provider-agnostic v1

**Category**:
A product-owned grouping used to organize messages independently of provider folders and labels; it may be product-provided or user-created.
_Avoid_: Folder, Gmail label, Outlook category

**System Category**:
A product-provided **Category** available without user setup.
_Avoid_: Default folder, provider label

**Orders**:
A **System Category** for transactional purchase messages, including confirmations, invoices, receipts, payment updates, shipping, delivery, cancellations, and returns.
_Avoid_: Invoices

**Newsletters & Promotions**:
A **System Category** for subscribed newsletters and commercial marketing messages, including campaigns, coupons, sales, and advertising email.
_Avoid_: Promotions, Newsletters & Ads

**People**:
A **System Category** for person-to-person correspondence primarily authored by a human for direct conversation, excluding bulk mail, newsletters, transactional notifications, and automated campaigns.
_Avoid_: Contacts, human-looking sender

**Custom Category**:
A user-created **Category** for organizing messages according to the user's own needs.
_Avoid_: Custom folder, provider label

**Category Description**:
Optional user-written guidance that explains when a **Custom Category** should apply.
_Avoid_: Prompt, rule

**Category Appearance**:
The icon and color associated with a Category, used together with its text label and never as the sole indicator of meaning.
_Avoid_: Custom artwork, color-only category

**Message Category**:
One of zero or more Categories assigned to an individual message, such as newsletters and promotions, invites, orders, or flights.
_Avoid_: Exclusive category, Thread category, folder

**Stable Provider Message Identity**:
A provider-specific message identity used to match the same message across devices. Gmail uses its immutable message resource ID; Microsoft Graph connections require immutable IDs; IMAP uses its immutable provider-mailbox identity plus UIDVALIDITY and UID; POP3 connections require UIDL; and Exchange uses its provider item identity. A provider that cannot supply the required stable identity is not eligible for a synchronized Mailbox Connection. Provider adapters retain a verified repair mapping for provider-issued identity changes such as moves; if repair is ambiguous or unavailable, they create a distinct product record rather than applying product state to the wrong message.
_Avoid_: Local database ID, backend message ID

**Uncategorized State**:
The state of a message when no **Message Categories** have been assigned, including historical mail that is not automatically categorized.
_Avoid_: Uncategorized category, forced category

**Thread**:
A group of related messages within one **Mailbox Connection**, shown together as a conversation.
_Avoid_: Category target

**Stable Thread Identity**:
A **Mailbox Connection**-scoped identity derived from a reliable provider conversation identity or verified RFC reply linkage and used to preserve product-owned Thread state across trusted devices.
_Avoid_: Subject, latest message identity

**System Categorization**:
Automatic assignment of one or more **Message Categories** by the product.
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
Locally encrypted storage for prefetched recent readable body representations and opened older readable body representations, excluding attachments and constrained by eviction controls.
_Avoid_: On-demand-only body cache, permanent body store, attachment archive

**Remote Message Content**:
Content referenced by a message but fetched from an external server only when the message is viewed, such as remote images.
_Avoid_: Message body, downloaded attachment

**Inline Image**:
An image placed at a position inside message content and delivered as a MIME part rather than fetched as **Remote Message Content**. A user-authored Inline Image occupies a position in the **Semantic Message Document**; a received Inline Image is resolved from its normalized Content-ID only when that message is explicitly opened.
_Avoid_: Image attachment, remote image

**Attachment**:
A file delivered with a received or outgoing message outside the ordered body content.
_Avoid_: Inline Image, Remote Message Content

**Downloaded Attachment**:
A device-local copy of a received **Attachment** retained after an explicit or policy-permitted download.
_Avoid_: Attachment, Draft Asset, synchronized attachment

**Draft Asset**:
The encrypted source bytes and metadata for an **Attachment** or **Inline Image** retained with a **Draft** before Outbox admission.
_Avoid_: Downloaded attachment, remote image

**Outgoing Content Store**:
The non-evicting encrypted 100 MB device-wide store shared by **Drafts**, **Send Reminders**, **Scheduled Sends**, and their authored semantic documents, attachments, inline images, and other message assets.
_Avoid_: Draft-only store, Bounded Encrypted Body Cache, provider Draft mailbox

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
User-owned preference that controls which categorized messages can produce visible notifications.
_Avoid_: Backend routing rule

**Generic Notification Fallback**:
An optional user setting that allows a visible new-mail notification when category-aware notification processing cannot finish in time.
_Avoid_: Default generic notification

**User Override**:
A category change made by the user after **System Categorization**.
_Avoid_: Recategorization

**Future Learning Signal**:
Positive or negative per-Category information from a **User Override** that can improve categorization of future messages without changing already categorized messages.
_Avoid_: Retroactive recategorization

**Category Conflict Rule**:
The rule for merging concurrent per-Category membership changes across trusted devices.
_Avoid_: Last-write-wins

**Synced Category**:
A **Category** that is available across the user's Apple devices without becoming provider-visible mailbox organization.
_Avoid_: Local-only category, provider label

**Product Account**:
An account owned by the product that identifies a user independently of their mail provider and Apple account.
_Avoid_: iCloud account, Gmail account, mailbox account

**Mail Profile**:
An end-to-end encrypted workspace inside one **Product Account** that owns a disjoint set of **Mailbox Connections** and the product-owned organization, automation, sending identities, and **Mail Workflow Preferences** applied to those connections.
_Avoid_: Product Account, provider account, shared workspace

**Default Profile**:
The lossless migrated **Mail Profile** that owns every pre-Profile **Mailbox Connection** and existing product-owned record in place without copying, resetting, or exposing that state.
_Avoid_: Startup Profile, default mailbox account

**Startup Profile**:
The device-local **Mail Profile** used only when opening a new app window. A restored window keeps its own last active Profile, and a targeted deep link takes precedence over both restoration and Startup Profile.
_Avoid_: Default Profile, default sending account

**Mail Profile Window**:
One app window whose navigation, Unified Mailboxes, Mail Views, search, composer, and message context are constrained to exactly one active **Mail Profile** while background synchronization continues for every Profile.
_Avoid_: Product Account window, combined workspace

**Profile Record Scope**:
The opaque Product Sync namespace owned by one **Mail Profile**. The **Default Profile** retains the deployed Product Account-scoped record identifiers; a new Profile receives a distinct opaque namespace.
_Avoid_: provider namespace, device-local directory

**Apple-First Sign-In**:
The Product Account sign-in strategy where Sign in with Apple is supported before email magic link.
_Avoid_: Password-first account

**Operational Account Data**:
Backend-readable account data needed to run identity, billing, device routing, and encrypted sync operations.
_Avoid_: User organization data, mailbox content

**Trusted Device**:
A user-approved device authorized to access one **Product Account** and participate in **End-to-End Encrypted Product Sync**.
_Avoid_: Mailbox Authorization, remembered login

**Trusted Device Credential**:
An unlisted device-only secret that proves a request comes from one **Trusted Device**; its digest, not the credential, is stored by the backend.
_Avoid_: Trusted Device ID, Apple identity token

**Device Revocation**:
A Product Account action that blocks one former **Trusted Device** from account APIs, push routing, and future encrypted sync data.
_Avoid_: Guaranteed remote erase, provider-token revocation

**Product Sync**:
Synchronization of product-owned user data across devices through the product's backend.
_Avoid_: iCloud sync, provider sync

**End-to-End Encrypted Product Sync**:
**Product Sync** where synced product data is readable only by the user's trusted devices.
_Avoid_: Server-readable sync, plaintext sync

**Mail Workflow Preference**:
A user-owned choice about handling mail that follows the user across trusted devices through **End-to-End Encrypted Product Sync**.
_Avoid_: Device setting, provider credential

**Compose Presentation Preference**:
The global **Mail Workflow Preference** that chooses partial or full-screen presentation when any new-message, reply, reply-all, or forward composer opens.
_Avoid_: Current composer size, per-draft layout

**Formatting Toolbar Preference**:
The global **Mail Workflow Preference** that controls whether the composer displays its formatting toolbar without disabling formatting capabilities.
_Avoid_: Plain-text mode, formatting disablement

**Recipient Suggestion**:
An on-device autocomplete candidate derived from local correspondence, recent recipients, permissioned Apple Contacts, or an optional device-authenticated Mail Provider directory.
_Avoid_: Backend contact, uploaded address query

**Inbox Cleanup Candidate**:
An individual message detected on device by the first-release Inbox Cleanup eligibility predicate: it currently belongs to Inbox, is read, is assigned the **Newsletters & Promotions** **System Category**, is older than 90 days, does not belong to a **Thread** with a **Pin**, and has no reply evidence. A **Pin** is Thread-scoped, so every message in that Thread fails the predicate. Messages assigned People, Invites, Orders, or Flights, and messages in Spam or Trash, are excluded. Other low-priority signals are not eligible until a later decision defines a deterministic predicate for them.
_Avoid_: Spam, automatically deleted message, whole Thread

**Inbox Cleanup Proposal**:
A user-reviewable collection of **Inbox Cleanup Candidates** proposed for a recoverable move to the Mail Provider's Trash after explicit confirmation.
_Avoid_: Automatic deletion, permanent erasure, archive suggestion

**Mailing List Identity**:
The subscription identity conveyed by standards-based mailing-list headers on an eligible message and used to scope an unsubscribe action.
_Avoid_: Display sender name, Thread identity, blocked sender

**Unsubscribe Suggestion**:
An on-device detection that the currently expanded or newest eligible message offers a standards-based action for leaving its **Mailing List Identity**.
_Avoid_: Spam report, sender block, automatic unsubscribe

**Contact Candidate**:
A proposed Apple Contacts record derived on device from one normalized sender name and email address in message metadata for People-classified direct correspondence with same-connection reply or repeated-correspondence evidence from the owning Mailbox Connection and Thread. Standards-Based Mail accepts bounded RFC encoded names but rejects groups, aliases, and malformed identities. Microsoft Graph keeps Sender, From, and every Reply-To identity separate; delegated, aliased, or multiple reply identities fail closed instead of being combined. Phone, organization, postal address, and URL fields may be derived only from a message body already available on the device; detection never fetches a missing body or synchronizes extracted fields.
_Avoid_: Recipient Suggestion, automatically created contact, provider directory entry

**Calendar Event Candidate**:
A proposed local calendar event derived on device from a structured calendar invitation or from an unambiguous date and time in a message body already available on the device. Detection never fetches a missing body or synchronizes extracted event values; ambiguous date, time zone, duration, or location requires native event review.
_Avoid_: Accepted invitation, Invite Message Category, automatically created event

**Raw Message Source**:
The exact provider-returned RFC 822 or MIME bytes for one message, fetched only after an explicit source-inspector action. The Apple client may parse those bytes into a separate header view, but Copy Source and `.eml` export preserve the original byte sequence; metadata-only fallback is labelled as non-exact and is never reconstructed into synthetic source.
_Avoid_: Reconstructed email, generated MIME source

**Attachment Preview**:
A device-local presentation of a **Downloaded Attachment** using a supported system preview rather than message-body rendering.
_Avoid_: Inline Image, Remote Message Content, attachment download

**Feature Suggestion Preference**:
A **Mail Workflow Preference** that enables or suppresses proactive suggestions for exactly one of Inbox Cleanup, Unsubscribe, Add to Contacts, or Add to Calendar.
_Avoid_: Smart Actions setting, device permission, shared feature toggle

**Device-Local Preference**:
A choice tied to one device's hardware, operating-system permission, appearance, storage, or diagnostics.
_Avoid_: Synced mail workflow

**Preference Conflict**:
Two changes to the same field of a **Mail Workflow Preference** that were made from the same older synchronized revision.
_Avoid_: Non-overlapping edit, upload-order winner

**Recovery Key**:
A user-held secret that can restore access to encrypted product data when no trusted device is available.
_Avoid_: Password reset, support recovery

## Relationships

- An **Apple-first private email client** runs on iOS, iPadOS, and macOS
- A **True email client** is responsible for mailbox access and message organization
- A **True email client** connects to one or more **Mail Providers**
- A **Product Account** may own multiple **Mailbox Connections**
- Every **Mailbox Connection** belongs to exactly one **Mail Profile**
- A newly drafted **Mail Profile** can be named and styled in device-local protected state while offline, retaining its opaque identity until encrypted Product Sync succeeds
- Duplicating a **Mail Profile** copies only the reviewed Profile-scoped configuration; it never copies Mailbox Connections, provider credentials, cached mail, Drafts, Outbox attempts, history, or connection-scoped pins
- Moving a **Mailbox Connection** between Profiles preserves its stable identity and device-local authorization, commits ownership and reviewed custom-Category copies atomically while online, and leaves source Profile-wide preferences in place
- A Profile-scoped query requires an explicit **Mail Profile**
- Every **Mail Profile Window** restores one device-local Profile; targeted deep links override restoration and the **Startup Profile**
- Provider credentials remain device-local and outside **Profile Record Scope**
- A **Mailbox Connection** links one **Product Account** to one provider mailbox account supplied by a **Mail Provider** and contains that account's **Provider Mailboxes**
- A **Product Account** may contain only one **Mailbox Connection** for a **Stable Provider Connection Key**
- Re-adding an existing provider mailbox authorizes or repairs its **Mailbox Connection** instead of creating a duplicate; after synchronization, trusted devices group equal **Stable Provider Connection Keys** under a durable encrypted merge record, choose the lexicographically lowest connection identifier as its winner, and atomically fence every loser at that record's merge epoch before an idempotent transfer of product-owned pins, categories, pending actions, and Outbox attempts. The winner records completed transfers by loser and merge epoch before a durable loser tombstone prevents resurrection; concurrent writes must retry against the winner and current epoch. Before a device deletes a losing record, it re-keys its local authorization and cached mail to the winner or requires authorization there, so no local credential or queued work is silently lost.
- A **Mailbox Connection** definition, including its reviewed non-secret address, username, and endpoint settings, synchronizes end-to-end encrypted across trusted devices without provider credentials
- Each trusted device needs its own **Mailbox Authorization** before it can access a synchronized **Mailbox Connection**
- **Mailbox Authorization** prefers provider OAuth but may use a password or app-specific password over **Secure Mail Transport**
- Passwords, app-specific passwords, and OAuth refresh tokens remain in the current device's Keychain
- **Remove Device Authorization** affects only the current device and preserves the synchronized **Mailbox Connection**
- **Remove Mailbox Connection Everywhere** removes synchronized connection and product-owned state from all trusted devices but never deletes provider mail
- A trusted device that receives **Remove Mailbox Connection Everywhere** purges its **Mailbox Authorization** and cached mail for that connection before any later provider access or synchronization
- Recreating a removed **Mailbox Connection** with the same **Stable Provider Mailbox Identity** advances a synchronized authorization generation; every device-local **Mailbox Authorization** is bound to one generation, so an offline credential from before removal requires reauthorization after reconciliation
- After wake or reconnect, a trusted device processes synchronized connection-removal tombstones before it resumes any queued **Provider Mail Action** or **Outgoing Delivery Attempt** for that connection
- **Delete Product Account** requires recent authentication and explicit confirmation, has no recovery grace period, and cannot be undone
- **Delete Product Account** removes backend operational account data, encrypted Product Sync payloads, and push routes and instructs reachable devices to purge local product data and mailbox credentials
- **Delete Product Account** never deletes provider mail and does not promise to revoke authorization already issued by a **Mail Provider**
- A **Standards-Based Mailbox Connection** requires both IMAP and SMTP before it is considered complete
- The **Approved Mail Engine Dependency** owns IMAP and SMTP transport, authentication, framing, parsing, MIME, IDLE, UID operations, and submission; product code owns durable state, role and capability policy, Stable Provider Message Identity, retry, and reconciliation. There is no product-owned IMAP or SMTP wire-protocol fallback; the legacy stream implementation remains only for POP3
- Gmail, **Standards-Based Mailbox Connections**, Microsoft Graph, and **On-Premises Exchange Connections** are **Full-Capability Mailbox Connections** only when every **Mailbox Role** required by their supported actions is mapped or successfully created; otherwise they remain incomplete for actions requiring a missing role
- A **Standards-Based Mailbox Connection** always supports provider read-state and star changes, exposes move-family actions only after verifying `MOVE` or `UIDPLUS`, and exposes role-targeting actions only when the required **Mailbox Role** has a trustworthy mapping
- A **Standards-Based Mailbox Connection** supports move, archive, and trash actions only when its server offers `MOVE` or `UIDPLUS` for targeted removal and returns a verified source-to-destination UID mapping such as `COPYUID`; it never uses an unrestricted expunge fallback that could remove unrelated messages
- A verified `COPYUID` continuation is persisted before UIDPLUS source deletion; recovery reuses that mapping rather than copying again, targets only the recorded source UIDs, and transfers local product state to the destination identity
- A **Full-Capability Mailbox Connection** supports read state, archive, move, delete and restore, spam state, compose, reply, reply all, forward, product-owned drafts, and Outbox recovery
- **Read Receipt** preferences distinguish responding to incoming requests from requesting receipts for outgoing messages
- Incoming **Read Receipt** requests default to asking the user every time and are never acknowledged silently
- Outgoing **Read Receipt** requests are off by default
- Pin and unpin are product-owned actions available across full and reduced connection types
- IMAP, SMTP, POP3, and Exchange Web Services require **Secure Mail Transport**
- **Secure Mail Transport** prefers implicit TLS, permits STARTTLS only before authentication, and has no invalid-certificate override
- **Mailbox Service Discovery** happens on the device and never uploads an email address or server configuration to the product backend
- A user reviews discovered endpoints before connection and may enter host, port, username, and security settings manually when discovery fails
- Exchange Online and Microsoft 365 use Microsoft Graph, while an **On-Premises Exchange Connection** uses Exchange Web Services
- A **Legacy POP3 Connection** leaves downloaded messages on the server by default
- A **Legacy POP3 Connection** does not promise server-synchronized folders, moves, flags, or real-time delivery
- A **Legacy POP3 Connection** does not support server-side body search; it may search locally retained metadata, while body search remains unavailable unless the matching body is already available in the **Bounded Encrypted Body Cache**
- A **Unified Mailbox** aggregates a corresponding **Mailbox Role** or product-owned aggregate view across all **Mailbox Connections**
- The permanent **Unified Mailboxes** are Inbox, Snoozed, Pins, Drafts, **Sent Mailbox**, Archive, All Mail, Spam, and Trash
- A **Thread Snooze** is Profile-scoped product state, not a Provider Mail Action: it hides the Thread from ordinary Inbox until its absolute due instant or the arrival of a new message, while keeping the Thread in Snoozed, All Mail, and Profile-scoped search without moving, archiving, labeling, or deleting provider mail
- Rescheduling a **Thread Snooze** transfers Return-to-Attention ownership to the changing Trusted Device; Quiet, Profile Lock, OS authorization, and lock-screen content policy still decide whether that owner may present an interruption
- A **Follow-Up Nudge** is Profile-scoped encrypted state attached to a sent Thread; it is created only by explicit scheduling or acceptance of an on-device suggestion and never drafts or sends a message
- Follow-Up eligibility requires a latest sent message from an authorized **Sending Identity**; a newly observed reply from outside the recorded authorized identity set cancels the current nudge revision, while an authorized alias does not
- A due **Follow-Up Nudge** remains visibly overdue when interruption is unavailable; the current notification-owning Trusted Device may request Return-to-Attention only when the Profile preference, Quiet, Profile Lock, OS authorization, and lock-screen content policy permit it
- **All Mail** is a product-local aggregate of every non-Spam, non-Trash message across all **Mailbox Connections**, not a required provider mailbox role
- **Outbox** is a conditional unified item rather than a permanent mailbox
- Provider-specific custom folders and labels remain under their **Mailbox Connection** and do not gain synthetic unified views
- Moving a Gmail message from a provider-specific label records and removes that selected source label while preserving every unrelated label
- Provider-native semantics or IMAP special-use markers assign a **Mailbox Role** when they are unambiguous
- A user explicitly maps any required **Mailbox Role** that a provider-synchronized connection does not identify unambiguously; if no provider mailbox can supply a required role, the client offers to create one when the provider permits it, otherwise the connection remains incomplete for actions requiring that role and has no product-local fallback. A **Legacy POP3 Connection** instead uses product-owned local roles for its reduced organization contract.
- **Mailbox Roles** are never inferred from localized folder names and user mappings may be changed later
- Changing a **Mailbox Role** mapping reclassifies existing local metadata and applies to future synchronization; the prior mapping is retained until the new mapping completes and may be restored if the change fails
- When a **Mailbox Role** mapping changes, every pending **Provider Mail Action** whose target or meaning changed is cancelled until the user reconfirms it against the new mapping
- A user may select either a **Unified Mailbox** or a mailbox within one **Mailbox Connection** to scope the messages being viewed
- A **Mail View** filters the **Threads** in the selected mailbox or **Unified Mailbox**
- Selecting Drafts or Outbox automatically selects the **All Messages Mail View**, because unsent items have no provider message identity or Category membership; switching back to a Thread scope preserves the prior selected Mail View when it is still available
- A **Thread** appears in a **Mail View** when any current message in that thread matches the view; the whole conversation remains available and retains latest-message ordering
- Important and the **All Messages Mail View** are permanent **Mail Views**; the remaining **Mail Views** are user-configurable
- The Important **Mail View** matches the union of user-selected **System Categories** and **Custom Categories**; it is neither a separate message classification nor a substitute for **Pins**
- Important initially includes People, Invites, Orders, and Flights and excludes Newsletters & Promotions
- Each configurable **Mail View** matches exactly one **System Category** or **Custom Category**
- Every supported Apple layout exposes at most five **Mail Views**: Important, the **All Messages Mail View**, and up to three configurable Category views; additional Categories do not enter an overflow view
- Important and the **All Messages Mail View** remain in the first and second **Mail View** positions; users may reorder only the three configurable Category views
- Settings exposes Mail View configuration: users choose the Categories included by Important, assign one eligible Category to each empty configurable slot, replace an assigned Category, and reorder configurable slots
- New users start with Orders, Newsletters & Promotions, and Flights in the three configurable **Mail View** positions
- Configurable **Mail Views** cannot duplicate a Category; deleting a Custom Category or disabling any Category removes it from Important and its configurable slot without substitution, allowing fewer than five visible views until the user fills the empty slot
- If the selected configurable **Mail View** disappears, selection falls back to the **All Messages Mail View** while preserving the selected mailbox and Thread when possible
- Each **Mail View** badge shows the selected mailbox scope's unread-Thread count capped at 99+; a Thread counts once in each matching view when any of its messages is unread
- One global **Mail View** configuration applies across all mailboxes; changing the selected mailbox changes only the view's message scope
- **Mail View** configuration is a **Mail Workflow Preference** synchronized through **End-to-End Encrypted Product Sync**
- The selected mailbox and **Mail View** are transient device-local navigation state; a new application session starts in Unified Inbox with Important selected
- The **Compose Presentation Preference** defaults to partial and applies globally to every compose type; changing one open composer to full screen does not change the preference
- The **Formatting Toolbar Preference** synchronizes globally and hides only the formatting toolbar; Markdown, keyboard, context-menu, document, and delivery formatting remain available
- A **Unified Mailbox** interleaves mailbox-scoped **Threads** by latest message time rather than grouping them by account
- Every thread in a **Unified Mailbox** visibly identifies its source **Mailbox Connection**
- Background synchronization preserves the selected **Thread** when newer threads enter the list
- The unified **Sent Mailbox** is always available
- After SMTP accepts a message for a **Standards-Based Mailbox Connection**, the client appends a verified copy to its mapped Sent role; if that append cannot be confirmed, it retries or reconciles only the sent-copy operation, visibly marks the copy as pending, and never resends the delivered message
- Before attempting that Sent append, the trusted device encrypts the exact accepted MIME in a connection-scoped journal; a stable RFC Message-ID prevents duplicate appends during recovery, and the journal is removed only after Sent containment or append is confirmed
- An ambiguous post-content SMTP outcome is never retried automatically and requires explicit user reconciliation
- The **Outbox** appears only while it contains a scheduled, pending, retrying, failed, or needs-attention outgoing message
- Composer edits continuously autosave to an encrypted **Draft**; if the **Outgoing Content Store** cannot admit the latest edit, the composer visibly retains unsaved state and blocks closing, sending, and discard until the edit is saved or explicitly abandoned
- Sending removes a **Draft** only after the outgoing message is durably admitted to the **Outbox**, which atomically retains the complete rendered MIME payload and referenced Draft Assets until the attempt becomes terminal or is cancelled
- **Draft Assets** synchronize through **End-to-End Encrypted Product Sync** as independently encrypted, verified chunks; Send remains unavailable until every required asset is complete and valid on the sending device
- Product-authored Drafts are distinct from provider-hosted Draft mailboxes: provider Draft messages remain read-only provider mail in v1 and are not imported, mirrored, or retired by Product Sync Draft operations
- Discarding a **Draft** or durably admitting it to the **Outbox** writes a synchronized tombstone. If an offline edit conflicts with that tombstone, the tombstone preserves the sent or discarded Draft while the edit is materialized as a user-visible conflicted Draft copy; referenced Draft Assets remain retained until the conflict copy is resolved or discarded, then become eligible for cleanup
- A **Scheduled Send** is a synchronized Outbox commitment, while a **Send Reminder** remains attached to a Draft and never authorizes delivery
- Scheduled Send is available for every send-capable new-message, reply, reply-all, and forward composer and uses the same product-owned behavior for every send-capable **Mailbox Connection**
- A Scheduled Send is admitted only after its complete payload synchronizes end-to-end encrypted, its Draft tombstone commits, and its opaque operational schedule is activated; admission fails closed while offline or uncertain and leaves the message as a Draft
- For Scheduled Send, the backend may read only the Product Account, opaque schedule identity, absolute delivery instant, 24-hour deadline, expected encrypted-record revision, scheduled wake identifier, admission state, claim owner, claim generation, claim phase and timestamps, compatible device-authorization generation, and terminal or cleanup state without message outcome details; recipients, subject, body, assets, selected Mailbox Connection, and provider results remain end-to-end encrypted, and provider credentials remain device-local
- Scheduled Send delivery is best-effort at or after its absolute selected instant; it never promises exact background execution, and an item more than 24 hours late requires user attention instead of sending automatically
- Any compatible trusted device with the selected **Mailbox Authorization** and **Scheduled Delivery Authorization** may acquire the one active **Scheduled Send Claim**; provider handoff fences every other device until its result is reconciled
- Opening a Scheduled Send for editing first acquires a synchronized edit fence; editing, rescheduling, cancellation, mode conversion, and delivery claiming compare the same synchronized revision so they cannot create duplicate delivery commitments
- Cancelling a Scheduled Send restores an editable Draft, while cancelling a Send Reminder removes only the reminder; explicit mode conversion keeps exactly one synchronized state active
- Scheduled Send never silently changes its selected Mailbox Connection, and **Send Now** remains subject to the **Undo Send Window**
- Removing authorization from one device preserves Scheduled Sends for other eligible devices; removing their Mailbox Connection everywhere or deleting the Product Account warns and cancels affected commitments
- The **Outgoing Content Store** has a non-evicting 100 MB device-wide limit shared by Drafts, Send Reminders, Scheduled Sends, and their documents and assets
- Markdown syntax acts as an input shortcut over the **Semantic Message Document** rather than becoming the stored or sent message format
- Formatting controls and context actions edit the same **Semantic Message Document**
- Outgoing delivery derives interoperable HTML and plain-text alternatives from the **Semantic Message Document**
- The v1 **Semantic Message Document** supports paragraphs, headings one through three, bold, italic, underline, strikethrough, bulleted and numbered lists, blockquotes, inline code, code blocks, links, undo, and redo
- The **Semantic Message Document** may contain **Inline Images** at authored cursor positions
- Font families, arbitrary font sizes, text and background colors, alignment, and tables are outside the v1 formatting vocabulary
- Rich-message delivery is verified against current Apple Mail on iOS and macOS, Gmail web and mobile, and Outlook web and desktop, while every message includes a standards-compatible plain-text alternative
- Pointer right-click, touch long-press, and keyboard context-menu access expose the same current-block choices: paragraph, headings one through three, bulleted list, numbered list, blockquote, and code block; inline styles remain selection-based
- Pasting or dropping image data into the message body creates an **Inline Image**, while choosing an image through the attachment picker creates an **Attachment**; an explicit context action converts either representation to the other
- Before **Outbox** admission, the client computes final transfer-encoded MIME size and enforces a known limit from the selected sending **Mailbox Connection**; an unknown provider limit permits attempted delivery with a visible estimate, while excess size requires removal or local image compression
- During provider delivery, outgoing **Attachments** and **Inline Images** travel from the trusted device to the **Mail Provider** without passing through the product backend; their encrypted Draft Assets synchronize through **Product Sync** before handoff
- The **Undo Send Window** defaults to 10 seconds and may be disabled or set to 20 or 30 seconds
- Cancelling during the **Undo Send Window** prevents provider handoff; the product never describes this as recalling a message already accepted by a provider
- Transiently failed **Outgoing Delivery Attempts** retry automatically with bounded exponential backoff
- Permanently failed **Outgoing Delivery Attempts** stop until the user resolves authentication, policy, recipient, or message problems
- Pending and failed Outbox messages remain editable and cancellable until an **Outgoing Delivery Attempt** has been handed to its provider; an in-flight attempt must first reach a terminal state
- Editing an eligible Outbox message creates a new **Outgoing Delivery Attempt** rather than mutating an attempt already in flight
- A **Pin** is protected by **End-to-End Encrypted Product Sync**, is keyed by its **Mailbox Connection** and **Stable Thread Identity**, and remains independent of provider-visible flags
- Pinned **Threads** from all **Mailbox Connections** appear together in the unified pinned view
- Legacy message Pins migrate idempotently to their containing **Thread**, deduplicate by **Stable Thread Identity**, and remain until the corresponding Thread **Pin** is durably synchronized; a message without reliable linkage forms a one-message Thread
- A **True email client** supports **Provider Mail Actions**
- An offline **Provider Mail Action** becomes a **Pending Provider Action** and updates local presentation optimistically
- **Pending Provider Actions** are ordered per **Mailbox Connection** and retried when connectivity returns
- A permanently rejected **Pending Provider Action** restores provider-derived state, replays later pending actions in order, and produces a visible failure without overwriting newer optimistic changes
- Each **Pending Provider Action** has a stable idempotency key and immutable attempt record; an ambiguous provider response is reconciled before retrying so the provider mutation is not duplicated
- For an ambiguous IMAP move, archive, or copy, the client retries only after it verifies the source-to-target mapping; otherwise it stops the action for user resolution rather than replaying it
- A **Muted Thread** is protected by **End-to-End Encrypted Product Sync**, keyed by its **Mailbox Connection** and **Stable Thread Identity**, and scoped to one **Mail Profile**
- A **Muted Thread** remains in Inbox, Mail Views, All Mail, and search with ordinary unread behavior; only notifications and proactive suggestions are suppressed until Unmute
- New replies do not clear a **Muted Thread**, and rethreading repairs its identity through the stable anchor message without changing provider mail
- Product-owned actions such as **Pin** and **Muted Thread** do not wait for a mail provider and synchronize independently
- A **Blocked Sender** is a profile-scoped **Mail Workflow Preference** protected by **End-to-End Encrypted Product Sync**; the backend receives neither its readable address nor provider execution requests
- Blocking applies only to future arriving messages whose normalized sender address matches exactly, suppresses their new-message notifications, and enqueues a recoverable move to Trash through the owning **Mailbox Connection** when that connection supports the action
- Unblocking stops future enforcement but does not restore mail already moved to Trash; devices without local authorization retain the synchronized preference and report that enforcement is waiting for an authorized trusted device
- A bulk selection may span multiple **Mailbox Connections** but exposes only actions supported by every selected connection
- Each bulk batch expands into ordered actions behind existing pending actions for its **Mailbox Connection**; execution is serialized per connection, while cross-connection batches may proceed independently and preserve successful batches when another connection fails
- **Gmail-first provider support** orders provider delivery as multiple Gmail **Mailbox Connections**, generic IMAP and SMTP, Microsoft Graph, then POP3 and Exchange Web Services; JMAP is deferred
- A **Synced Category** belongs to the product, not to a **Mail Provider**
- A **Provider Mail Action** may change provider state, but a **Message Category** does not
- A **Product Account** identifies the user for **Product Sync**
- **Product Sync** shares **Synced Categories** across the user's devices
- **End-to-End Encrypted Product Sync** prevents the product backend from reading **Synced Categories**
- A **Recovery Key** can restore access to data protected by **End-to-End Encrypted Product Sync**
- A **Message Category** is assigned to an individual message, not to a **Thread**
- A message may have multiple **Message Categories**
- A **Message Category** syncs across devices by its **Mailbox Connection** and **Stable Provider Message Identity**
- Legacy single-category assignments migrate idempotently to one-member Category sets while preserving assignment source, override state, and learning signals; mixed-version synchronization remains readable and cannot collapse a multi-category set to one value
- A **Thread** groups related messages without being the categorization target
- A **Thread** never spans multiple **Mailbox Connections**, including when shown in a **Unified Mailbox**
- A **Thread** uses a reliable provider conversation identity when available, otherwise RFC message and reply identifiers
- Subject similarity alone never combines messages into a **Thread**, and messages without reliable linkage remain separate
- Selecting a **Thread** opens its conversation rather than only its latest message
- The conversation reader orders messages newest to oldest and expands every message, with the newest message at the top
- Reply, Reply All, Forward, and the fixed reader toolbar's multi-select Category control target the newest message; Archive, Delete, Move, Spam, **Pin**, **Muted Thread**, and read-state actions target the entire **Thread**
- The Category control stages multiple membership changes and commits them as one **User Override** only when the user applies them; cancelling commits nothing, while an offline apply updates local presentation and queues encrypted synchronization
- The Category control includes Add New, which opens the same required-name and optional-**Category Description** creation flow used in Settings
- Creating a Custom Category commits independently and preselects it in the open control; cancelling message assignment keeps the new Category but leaves the message unchanged
- Replies from a **Thread** use that thread's **Mailbox Connection** identity
- Replies and forwards default to their source **Thread** identity rather than the **Default Sending Connection**
- If a source **Thread** connection cannot send on the current device, the user must authorize it or explicitly select another sender; the product never silently substitutes an identity
- A new message defaults to the **Default Sending Connection** and always exposes its sending identity
- Recipient autocomplete ranks local correspondents, recent recipients, permissioned Apple Contacts, and optional device-authenticated provider-directory results; manual valid addresses remain available and neither addresses nor queries pass through the product backend
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
- **Orders** replaces the narrower Invoices **System Category** while preserving existing assignments and preferences through migration
- **Newsletters & Promotions** replaces the narrower Promotions **System Category** while preserving existing assignments and preferences through migration
- **People** contains direct person-to-person correspondence rather than every message with a human-looking sender
- **People** follows **New-Mail-Only Categorization** on rollout; historical mail receives it only through explicit **Bounded Historical Categorization**
- System Categorization independently assigns every confidently matching purpose-specific **System Category**; **People** is assigned only as the fallback when no purpose-specific Category matches direct correspondence
- A **Product Account** may have multiple **Custom Categories**
- The legacy single Custom Category migrates idempotently into the multi-category collection without changing its identity, description, assignments, notification rules, or learning signals and without automatically adding a **Mail View**; if its name collides case-insensitively with a System Category, migration renames the Custom Category by appending ` (Custom)` and, if needed, a numeric suffix, truncating the legacy name as needed to preserve the 40-character limit
- The multi-Custom-Category collection activates only after a synchronized minimum-client generation fences legacy singleton clients; updated devices dual-write and merge the legacy definition until every trusted device acknowledges that generation or is revoked, then retire the singleton record
- A **Custom Category** may have a **Category Description**
- Deleting a Custom Category writes a synchronized tombstone, removes it from active Mail Views and notification eligibility, and preserves historical message memberships and learning records as inactive references until every trusted device has observed the tombstone; an offline edit conflicts with the tombstone rather than recreating the Category silently
- Custom Category names are trimmed, contain 1–40 characters, and are case-insensitively unique across System and Custom Categories; descriptions contain at most 500 characters
- System Categories have fixed product-defined **Category Appearance**; Custom Categories choose from curated SF Symbols and an accessibility-tested color palette, and their appearance synchronizes through **End-to-End Encrypted Product Sync**
- System Categorization evaluates every enabled **Custom Category** independently and may assign several alongside System Categories; disabling a Custom Category affects only future automatic assignment
- **System Categorization** uses **Minimized Classification Input** before inspecting message body text
- A message in **Uncategorized State** has no **Message Category**
- **System Categorization** may assign one or more **Message Categories** to a message in **Uncategorized State**
- Historical mail remains in **Uncategorized State** under **New-Mail-Only Categorization**
- A **User Override** may become a **Future Learning Signal**
- Adding a Category through a **User Override** creates a positive **Future Learning Signal**, while removing one creates a negative signal for that Category
- A **Future Learning Signal** must not change existing **Message Categories**
- Automatic categorization of new mail may be disabled globally
- A **System Category** may be disabled for future **System Categorization** without removing or changing existing **Message Categories**
- The identities and names of **System Categories** are product-defined and cannot be edited as custom categories
- Resetting learned sender signals affects only future categorization and does not change existing **Message Categories**
- **Bounded Historical Categorization** exposes progress and may be cancelled without undoing assignments already completed
- The **Category Conflict Rule** merges concurrent changes to different Categories, gives user actions priority over system actions, and gives a concurrent user removal priority over a user addition of the same Category
- **Durable Message Metadata** is retained separately from the **Bounded Encrypted Body Cache**
- **Durable Message Metadata** is read locally before mailbox synchronization updates it
- **Initial Mailbox Availability** requires the newest 50 message metadata, or all provider-visible messages when fewer exist, and does not wait for full history
- **Historical Metadata Backfill** continues after the mailbox becomes usable and reports progress separately
- **Historical Metadata Backfill** pauses under low storage, low power, or network loss and resumes when conditions permit
- Completing **Historical Metadata Backfill** does not require retaining historical message bodies
- Body prefetch begins after **Initial Mailbox Availability** rather than delaying the newest message list
- The **Bounded Encrypted Body Cache** prefetches body text for a recent working set without prefetching attachments or Inline Images
- For each **Mailbox Connection**, the prefetched recent working set contains at most 500 distinct messages combined across Inbox and **Sent Mailbox**, selected at one synchronization reference instant from messages whose applicable timestamp falls from that instant minus 30 days through that instant, inclusive, ordered by newest applicable timestamp first; duplicate appearances use the later applicable timestamp, and **Stable Provider Message Identity** is the deterministic tie-breaker
- A synchronization first computes a cache-fitting combined protected set: selected-recent candidates take priority in recency order, then bodies belonging to pinned **Threads** in most-recently-read Thread and message order, stopping when eligible eviction space is exhausted. Applying a new selection may drop an existing pin-only body protection to admit a selected-recent candidate; the dropped body then follows last-resort pinned-Thread eviction. Only admitted candidates are protected; candidates of the same selection never evict one another, and a candidate that still cannot free eligible space is refused and remains on demand until a later synchronization finds space
- Every non-Spam, non-Trash message body in a pinned **Thread** is eligible for prefetch regardless of the 30-day and 500-message cutoffs, subject to that cache-fitting protected-set admission rule; otherwise the Thread metadata and **Pin** remain while the missing body is fetched on demand
- Spam, Trash, attachments, and older unpinned message bodies remain on-demand; Spam and Trash exclusion overrides a Thread **Pin** for body prefetch
- Complete **Drafts**, including their **Semantic Message Document** and **Draft Assets**, remain available offline as product-authored data in the **Outgoing Content Store** and synchronize through **End-to-End Encrypted Product Sync** to trusted devices; outgoing content is never evicted automatically, and a full store prevents saving additional authored content until the user removes or shortens an item. Incoming content that would exceed the local limit remains encrypted in Product Sync and is marked pending local storage rather than discarded; it is admitted after space is freed. When trusted devices edit the same Draft from the same synchronized revision while offline, synchronization preserves both versions: the later upload remains the original Draft and the other becomes a user-visible conflicted Draft copy; neither is silently overwritten
- The **Bounded Encrypted Body Cache** has a 500 MB device-wide limit
- Cache eviction removes eligible opened older non-pinned bodies first, then eligible non-pinned prefetched bodies, then least-recently-read pinned bodies as a last resort; the current cache-fitting protected set is never eligible, and a later selection may stop protecting a pinned body when the hard cap requires it
- Evicting a body from a pinned **Thread** preserves the Thread's **Pin** and fetches the body again on demand
- **Outgoing Content Store** data does not count against the body-cache limit, but Drafts, Send Reminders, Scheduled Sends, and their documents and assets share its separate 100 MB limit
- **Remote Message Content** is requested per device, defaults to asking the user, and may be configured to never load or always load
- One-message consent to load **Remote Message Content** is scoped to the current presentation; remote image requests use an isolated cookie-free and credential-free HTTPS path, reject any literal or resolved non-public destination, pin one validated public address while authenticating the original TLS hostname, repeat that boundary for every redirect, and keep loaded bytes presentation-scoped
- Known **Tracking Pixels** remain blocked when other **Remote Message Content** is allowed
- Explicitly opening retained Gmail HTML may resolve only sanitized, referenced, bounded, supported MIME Inline Images into the isolated presentation; missing or invalid parts fail independently, and their plaintext bytes remain presentation-scoped in memory without entering prefetch or the body cache
- Building a reply or forward quote never fetches **Remote Message Content**; quoted HTML is sanitized, blocked images remain non-loading placeholders, and unavailable embedded content or attachments are excluded unless the user explicitly downloads them
- Clearing cached bodies or downloaded attachments removes only device-local copies and never deletes provider mail
- **System Categorization** may use the **Bounded Encrypted Body Cache** when **Minimized Classification Input** is insufficient
- **Minimal Push Metadata** may route a mailbox-change wakeup without exposing message bodies, provider tokens, categories, or classification data; Gmail's provider-supplied email address and history identifier are permitted only as transient push-routing inputs, must not be persisted or included in application logs, and must be discarded after the wakeup is routed
- **Best-Effort Background Freshness** uses provider push where available, active IMAP connections, system-scheduled background refresh, and foreground synchronization
- A **Standards-Based Mailbox Connection** uses IDLE only when the verified server capabilities advertise it, reconnects an interrupted IDLE session with bounded backoff, and immediately synchronizes after an IDLE event while polling remains the fallback
- Every authorized **Mailbox Connection** synchronizes on app launch and foreground activation
- While the app remains active, provider signals are supplemented by a five-minute fallback poll and manual refresh
- Mailbox views observe local **Durable Message Metadata** so synchronized changes appear without reopening the view
- Each **Mailbox Connection** exposes **Mailbox Sync Status** without blocking cached mail use
- Active initial availability, historical backfill, user-triggered refresh, synchronization needing attention, and failures appear in a bottom-anchored non-blocking status overlay above the **Mail View** bar; automatic background work appears only after one second
- The synchronization overlay reports measurable progress, replaces failure progress with a retry action, and never shifts the visible **Threads**
- A **Unified Mailbox** shows one aggregate synchronization overlay with combined measurable progress and expandable per-connection status; failures summarize how many connections need attention and expose retry
- Manual refresh and the last successful synchronization are visible globally, while detailed **Historical Metadata Backfill** progress also remains in connection details
- Missed or delayed background changes are reconciled when a trusted device next wakes or becomes active
- **Best-Effort Background Freshness** does not permit the backend to hold **Mailbox Authorization** or synchronize mail itself
- A **Category-Aware Notification** depends on local **System Categorization**
- A **Generic Notification Fallback** is optional and not the default notification behavior
- **Apple-First Sign-In** identifies a **Product Account**
- The backend may read **Operational Account Data** but not user organization data or mailbox content
- A **Notification Rule** is encrypted user data and is evaluated on trusted devices
- Global notification switch, category eligibility, and per-connection notification policy synchronize as encrypted **Mail Workflow Preferences**
- Inbox behavior, read-state rules, swipe assignments, compose behavior, signatures, templates, category configuration, and per-connection notification and **Read Receipt** policies are **Mail Workflow Preferences**
- A Mail Profile's **Quiet State** is encrypted user data: it synchronizes through **End-to-End Encrypted Product Sync**, may be indefinite or end at one absolute instant, and suppresses visible notifications and proactive suggestions without suspending mailbox synchronization, indexing, Outbox, or Scheduled Send work
- **Profile Lock** and its background grace period are **Device-Local Preferences**; when enabled they require device-owner authentication before mail UI or search can reveal Profile content, remove that Profile's Spotlight entries on lock, and suppress content-bearing notification presentation while background work continues
- Appearance, operating-system notification permission, sounds, badges, lock-screen content level, **Generic Notification Fallback**, remote-content and download behavior, storage controls, diagnostics, and the last-opened settings destination are **Device-Local Preferences**
- Diagnostic exports are built on the trusted device from allowlisted health and version fields; they exclude mailbox addresses and identifiers, message content, provider credentials, Categories, raw failures, and Product Sync plaintext
- Rebuilding local indexes or clearing and resynchronizing local mailbox data preserves provider mail, Mailbox Authorization, Drafts, Product Sync records, Pending Provider Actions, and Outbox deliveries
- Provider credentials remain device-local Keychain material rather than preferences synchronized through **Product Sync**
- **Device-Local Preferences** save without network access
- **Mail Workflow Preferences** save locally while offline and visibly remain pending until their encrypted Product Sync updates complete, except the global notification switch, category eligibility, and per-connection notification policy: their **Notification Rule** save contract requires connectivity and fails closed so an uncertain remote write leaves no background-eligible rules cache
- Non-overlapping offline preference changes merge by field
- A **Preference Conflict** preserves both values for explicit user resolution rather than choosing by device clock, upload order, or device identity
- Conflicting signatures and templates may preserve the competing value as a conflict copy
- **Device Revocation**, **Delete Product Account**, connection removal, authorization or reauthorization, server verification, and mailbox-role remapping require connectivity and cannot appear complete while offline; removing **Mailbox Authorization** locally remains available offline and deletes local Keychain credentials and cached mailbox data
- **Device Revocation** immediately blocks the revoked device from Product Account APIs and push routing
- For owner revocation, the Apple client retains and submits the selected Trusted Device ID, while Convex retains and resolves its account-scoped revocation target after sign-out; unregistering, reconnecting, or a late unregister cannot preserve live access or remove the durable identifier tombstone
- Every **Trusted Device** whose client supports device credentials presents its device-only **Trusted Device Credential** to Product Account, Product Sync, and push-relay APIs; routine reconnects preserve a valid credential so concurrent in-flight requests remain authorized, while a missing or stale credential is replaced; a Trusted Device ID alone is not authentication proof, and legacy devices reconnect after account-wide credential enforcement activates only when their exact pre-enforcement installation identifier was imported before the Product Account's migration marker was completed
- Existing Product Accounts cannot perform a new **Device Revocation** until deployment operators import the retained pre-enforcement Trusted Device inventory and complete that Product Account's identifier migration; already-tombstoned accounts remain fail-closed during migration, newly created accounts are complete immediately, and a completed migration cannot admit another identifier
- **Device Revocation** rotates Product Sync key material for the remaining **Trusted Devices**, preventing the revoked device from reading future synchronized changes
- A revoked device purges local product data and mailbox credentials when it next connects, but revocation cannot guarantee erasure of data already copied from an offline or compromised device
- Provider authorization must be revoked separately through the **Mail Provider** when its device-local credential may be compromised

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
- "bottom tab" was resolved as a mailbox-scoped **Mail View**, not a **Category** or mailbox; Important and All Messages are permanent while the remaining views are user-configurable.
- "important email" was resolved as membership in the user-configured union of Categories shown by the permanent Important **Mail View**, not a separate classification or **Pin**.
- "configurable bottom tab" was resolved as a one-Category **Mail View**, not an arbitrary multi-rule query; only Important aggregates Categories.
- "visible Mail View capacity" was resolved as five on every supported Apple layout: two permanent views and up to three configurable Category views, without a v1 overflow destination.
- "per-mailbox Mail Views" was resolved as one global synchronized **Mail View** configuration whose contents are scoped by the selected mailbox.
- "launch Mail View" was resolved as transient local navigation state that resets to Unified Inbox and Important at the start of every application session.
- "all emails tab" was resolved as the scoped **All Messages Mail View**, labeled “All,” not the **All Mail** mailbox.
- "selected email" was resolved as a mailbox-scoped **Thread** conversation with every message expanded and ordered newest to oldest; thread-level actions target the newest eligible message, not a single-message-only reader.
- "generic provider threading" was resolved as provider conversation identity or RFC reply-header linkage, never subject-only grouping.
- "default sender" was resolved as a user-selected **Default Sending Connection**, not the most recently used connection; replies and forwards retain their source thread identity.
- "unavailable default sender" was resolved as an authorization or explicit sender-choice prompt, not silent fallback to another Mailbox Connection.
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
- "push notifications" was resolved as **Category-Aware Notifications**, not generic new-mail notifications.
- "notification fallback" was resolved as optional **Generic Notification Fallback**, not default behavior.
- "account sign-in" was resolved as **Apple-First Sign-In**, not password-first account creation.
- "backend-readable account data" was resolved as **Operational Account Data**, not user organization data or mailbox content.
- "notification rules" were resolved as encrypted user data, not backend-readable routing rules.
