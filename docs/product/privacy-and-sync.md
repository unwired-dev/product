# Privacy, storage and synchronization: behavior notes

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/product/privacy-and-sync.md).

[Vocabulary](../domain/privacy-and-sync.md) · [Domain index](../../GLOSSARY.md)

Privacy and encryption boundaries remain applicable. Category-Aware Notification
and Generic Notification Fallback retain prototype meanings; replacement
notification behavior comes from
[ADR 0063](../adr/0063-notify-for-new-inbox-mail-without-categorization.md).

These observable requirements were separated from the former monolithic glossary
and its implementation notes. The reviewer owns the separate architecture companion
under the [implementation and review workflow](../agents/implementation-review.md).
“v1” and “first release” in these notes refer to their original feature scope.
They do not establish replacement launch requirements or proof that a feature is
implemented.

## Privacy boundary

- A **Private email client** keeps its privacy boundary consistent across supported platforms

## Encrypted sync and recovery

- **Product Sync** shares **Synced Categories** across the user's devices
- **End-to-End Encrypted Product Sync** prevents the product backend from reading **Synced Categories**
- A **Recovery Key** can restore access to data protected by **End-to-End Encrypted Product Sync**

## Local storage and background freshness

- **Durable Message Metadata** is retained separately from the **Bounded Encrypted Body Cache**
- **Durable Message Metadata** is read locally before mailbox synchronization updates it
- **Initial Mailbox Availability** requires the newest 50 message metadata, or all provider-visible messages when fewer exist, and does not wait for full history
- **Historical Metadata Backfill** continues after the mailbox becomes usable and reports progress separately
- **Historical Metadata Backfill** pauses under low storage, low power, or network loss and resumes when conditions permit
- Completing **Historical Metadata Backfill** does not require retaining historical message bodies
- Body prefetch begins after **Initial Mailbox Availability** rather than delaying the newest message list
- Message-body loading permits at most four concurrent pipelines account-wide and two per **Mailbox Connection**; a provider may lower only its own connection limit when its transport cannot safely multiplex.
- An open message permits at most six concurrent remote-image requests, with twelve account-wide; duplicate message or image requests share one task
- Each **Mailbox Connection** has at most one speculative prefetch or historical-work lane, which yields immediately to interactive work and never occupies another connection's capacity.
- The **Bounded Encrypted Body Cache** prefetches body text for a recent working set without prefetching attachments or Inline Images
- For each **Mailbox Connection**, the prefetched recent working set contains at most 500 distinct messages combined across Inbox and **Sent Mailbox**, selected at one synchronization reference instant from messages whose applicable timestamp falls from that instant minus 30 days through that instant, inclusive, ordered by newest applicable timestamp first; duplicate appearances use the later applicable timestamp, and **Stable Provider Message Identity** is the deterministic tie-breaker
- Selected-recent bodies take priority over pinned-Thread bodies when the cache is full. Only bodies that fit are protected; refused bodies remain on demand, and a pinned body may lose protection under the hard cap.
- Every non-Spam, non-Trash message body in a pinned **Thread** is eligible for prefetch regardless of the 30-day and 500-message cutoffs, subject to that cache-fitting protected-set admission rule; otherwise the Thread metadata and **Pin** remain while the missing body is fetched on demand
- Spam, Trash, attachments, and older unpinned message bodies remain on-demand; Spam and Trash exclusion overrides a Thread **Pin** for body prefetch
- Complete **Drafts**, including their **Semantic Message Document** and **Draft Assets**, remain available offline as product-authored data in the **Outgoing Content Store** and synchronize through **End-to-End Encrypted Product Sync** to trusted devices; outgoing content is never evicted automatically, and a full store prevents saving additional authored content until the user removes or shortens an item. Incoming content that would exceed the local limit remains encrypted in Product Sync and is marked pending local storage rather than discarded; it is admitted after space is freed. When trusted devices edit the same Draft from the same synchronized revision while offline, synchronization preserves both versions: the later upload remains the original Draft and the other becomes a user-visible conflicted Draft copy; neither is silently overwritten
- The **Bounded Encrypted Body Cache** has a 500 MB device-wide limit
- Cache eviction removes eligible opened older non-pinned bodies first, then eligible non-pinned prefetched bodies, then least-recently-read pinned bodies as a last resort; the current cache-fitting protected set is never eligible, and a later selection may stop protecting a pinned body when the hard cap requires it
- Evicting a body from a pinned **Thread** preserves the Thread's **Pin** and fetches the body again on demand
- **Outgoing Content Store** data does not count against the body-cache limit, but Drafts, Send Reminders, Scheduled Sends, and their documents and assets share its separate 100 MB limit
- **Remote Message Content** is requested per device, defaults to asking the user, and may be configured to never load or always load
- One-message consent authorizes only the current remote retrieval and later encrypted-cache reuse for the same stable message presentation; it does not authorize changed content or a new request. Remote image requests remain cookie-free and credential-free, use HTTPS and reject non-public destinations on every redirect.
- The **Authorized Remote Content Cache** has a fixed 250 MB device-wide limit separate from the 500 MB body cache; least-recently-used entries are evicted first, currently displayed content is protected, and Storage Settings provides Clear Remote Content
- Remote-content entries remain separated by Product Account, Mail Profile, connection, stable message and resource revision, never deduplicate across Profiles, become inaccessible with Profile Lock and follow Profile-removal deletion rules.
- Known **Tracking Pixels** remain blocked when other **Remote Message Content** is allowed
- Explicitly opening retained Gmail HTML may resolve only sanitized, referenced, bounded, supported MIME Inline Images into the isolated presentation; missing or invalid parts fail independently, admitted bytes remain encrypted with the versioned body-cache entry for later provider-free opens, and only their decoded presentation remains scoped to memory
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

## Historical category-based notification defaults

[ADR 0063](../adr/0063-notify-for-new-inbox-mail-without-categorization.md)
replaces these defaults for the focused release.

- A **Category-Aware Notification** depends on local **System Categorization**
- A **Generic Notification Fallback** is optional and not the default notification behavior

## Operational data and workflow preferences

- The backend may read **Operational Account Data** but not user organization data or mailbox content
- A **Notification Rule** is encrypted user data and is evaluated on trusted devices
- Global notification switch, category eligibility, and per-connection notification policy synchronize as encrypted **Mail Workflow Preferences**
- Inbox behavior, read-state rules, swipe assignments, compose behavior, signatures, templates, category configuration, and per-connection notification and **Read Receipt** policies are **Mail Workflow Preferences**
- A Mail Profile's **Quiet State** is encrypted user data: it synchronizes through **End-to-End Encrypted Product Sync**, may be indefinite or end at one absolute instant, and suppresses visible notifications and proactive suggestions without suspending mailbox synchronization, indexing, Outbox, or Scheduled Send work

## Profile protection and search

- **Profile Lock** and its background grace period are **Device-Local Preferences**; when enabled they require device-owner authentication before mail UI or search can reveal Profile content, remove that Profile's Spotlight entries on lock, and suppress content-bearing notification presentation while background work continues
- **Spotlight Mail Indexing** is an off-by-default **Device-Local Preference** scoped to one Product Account and Mail Profile. Its complete-file-protection index admits only sender, recipients, subject, date, Profile, Mailbox Connection, and opaque exact-message deep-link metadata; it excludes bodies, attachments, **Product Sync**, and the product backend. Lock, disablement, authorization revocation, message deletion, connection transfer, and Profile deletion remove stale entries

## Device-local data and preference conflicts

- Appearance, operating-system notification permission, sounds, badges, lock-screen content level, **Generic Notification Fallback**, remote-content and download behavior, storage controls, diagnostics, and the last-opened settings destination are **Device-Local Preferences**
- Diagnostic exports are built on the trusted device from allowlisted health and version fields; they exclude mailbox addresses and identifiers, message content, provider credentials, Categories, raw failures, and Product Sync plaintext
- Rebuilding local indexes or clearing and resynchronizing local mailbox data preserves provider mail, Mailbox Authorization, Drafts, Product Sync records, Pending Provider Actions, and Outbox deliveries
- Provider credentials remain device-local Keychain material rather than preferences synchronized through **Product Sync**
- **Device-Local Preferences** save without network access
- **Mail Workflow Preferences** save locally while offline and visibly remain pending until their encrypted Product Sync updates complete, except the global notification switch, category eligibility, and per-connection notification policy: their **Notification Rule** save contract requires connectivity and fails closed so an uncertain remote write leaves no background-eligible rules cache
- Non-overlapping offline preference changes merge by field
- A **Preference Conflict** preserves both values for explicit user resolution rather than choosing by device clock, upload order, or device identity
- Conflicting signatures and templates may preserve the competing value as a conflict copy
