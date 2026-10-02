# Mail organization: behavior notes

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/product/organization.md).

[Vocabulary](../domain/organization.md) · [Domain index](../../GLOSSARY.md)

These terms include prototype organization features and follow-up work.
References to a feature's first release or v1 retain their original scope; they
do not add that feature to the focused replacement release.

These observable requirements were separated from the former monolithic glossary
and its implementation notes. The reviewer owns the separate architecture companion
under the [implementation and review workflow](../agents/implementation-review.md).
“v1” and “first release” in these notes refer to their original feature scope.
They do not establish replacement launch requirements or proof that a feature is
implemented.

## Product-owned actions

- Pin and unpin are product-owned actions available across full and reduced connection types

## Snooze and follow-up notes

Interruption and protection terms are defined in the [privacy and sync glossary](../domain/privacy-and-sync.md).

- A **Thread Snooze** is Profile-scoped product state, not a Provider Mail Action: it hides the Thread from ordinary Inbox until its absolute due instant or the arrival of a new message, while keeping the Thread in Snoozed, All Mail, and Profile-scoped search without moving, archiving, labeling, or deleting provider mail
- Rescheduling a **Thread Snooze** transfers Return-to-Attention ownership to the changing Trusted Device; Quiet State, Profile Lock, OS authorization, and lock-screen content policy still decide whether that owner may present an interruption
- A **Follow-Up Nudge** is Profile-scoped encrypted state attached to a sent Thread; it is created only by explicit scheduling or acceptance of an on-device suggestion and never drafts or sends a message
- Follow-Up eligibility requires a latest sent message from an authorized **Sending Identity**; a newly observed reply from outside the recorded authorized identity set cancels the current nudge revision, while an authorized alias does not
- A due **Follow-Up Nudge** remains visibly overdue when interruption is unavailable; the current notification-owning Trusted Device may request Return-to-Attention only when the Profile preference, Quiet State, Profile Lock, OS authorization, and lock-screen content policy permit it

## Prototype Mail Views and interface behavior

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
- The interface uses an Apple-native, content-first visual system that respects the device's System, Light, or Dark appearance preference and renders coherently in either appearance
- Mail lists and reading surfaces use a flat hierarchy with separators rather than nested cards; typography prioritizes sender, subject, and preview in that order
- By default, each Thread-list row presents sender and time first, subject second, and a single-line preview plus only essential attachment, pin, Category, and source-connection status third; existing density and zero-through-three-line preview preferences preserve that hierarchy and retain each person's saved choice
- Unread Threads use stronger sender and subject weight together with a small accent indicator; neither unread state nor any other status relies on color alone
- A real contact photo may aid recognition, but the list does not generate an initials avatar for every sender; swipe, pointer, and keyboard actions remain available without permanently filling rows with action buttons
- One restrained accent color identifies selection and primary actions, while all other color communicates a labeled status and is never the only status indicator
- Controls retain native platform sizing and comfortable hit targets; translucent material is reserved for floating controls and the nonmodal composer rather than ordinary content containers
- Regular-width layouts retain three stable columns, while compact layouts collapse those destinations into native navigation
- The regular-width sidebar presents the active Profile and search first, a prominent Compose action second, primary Unified Mailboxes before secondary Archive, All Mail, Spam, and Trash, then collapsible connection sections containing provider folders and labels
- Settings remains fixed at the bottom of the sidebar, while synchronization or authorization problems appear beside the affected **Mailbox Connection** rather than as global status
- Settings owns navigation state independently from mailbox synchronization and composer presentation: Mac and Catalyst use a dedicated native Settings window available through `Command-,`, iPad uses an in-app two-column Settings workspace, and iPhone pushes a one-column Settings destination into the existing navigation stack
- Opening Settings or a deep-linked Settings destination never waits for Thread, message-body, image, prefetch, or historical synchronization work
- The Settings shell always opens from local state; a destination-specific load or save failure leaves existing values visible, shows a concise inline error and Retry only in that detail pane, and keeps the sidebar and unrelated destinations usable

## Pins

- A **Pin** is protected by **End-to-End Encrypted Product Sync**, is keyed by its **Mailbox Connection** and **Stable Thread Identity**, and remains independent of provider-visible flags
- Pinned **Threads** from all **Mailbox Connections** appear together in the unified pinned view
- Legacy message Pins migrate to their containing **Thread**, deduplicate and remain until the Thread **Pin** synchronizes durably; a message without reliable linkage forms a one-message Thread.

## Mute and blocked senders

- A **Muted Thread** is protected by **End-to-End Encrypted Product Sync**, keyed by its **Mailbox Connection** and **Stable Thread Identity**, and scoped to one **Mail Profile**
- A **Muted Thread** remains in Inbox, Mail Views, All Mail, and search with ordinary unread behavior; only notifications and proactive suggestions are suppressed until Unmute
- New replies do not clear a **Muted Thread**, and repaired threading preserves its mute state without changing provider mail.
- Product-owned actions such as **Pin** and **Muted Thread** do not wait for a mail provider and synchronize independently
- A **Blocked Sender** is a profile-scoped **Mail Workflow Preference** protected by **End-to-End Encrypted Product Sync**; the backend receives neither its readable address nor provider execution requests
- Blocking applies only to future arriving messages whose normalized sender address matches exactly, suppresses their new-message notifications, and enqueues a recoverable move to Trash through the owning **Mailbox Connection** when that connection supports the action
- Unblocking stops future enforcement but does not restore mail already moved to Trash; devices without local authorization retain the synchronized preference and report that enforcement is waiting for an authorized trusted device

## Product categories

- A **Synced Category** belongs to the product, not to a **Mail Provider**
- A **Provider Mail Action** may change provider state, but a **Message Category** does not

## Category membership

- A **Message Category** is assigned to an individual message, not to a **Thread**
- A message may have multiple **Message Categories**
- A **Message Category** syncs across devices by its **Mailbox Connection** and **Stable Provider Message Identity**
- Legacy single-category assignments migrate to one-member Category sets while preserving assignment source, override state and learning signals; mixed-version synchronization remains readable and cannot collapse a multi-category set to one value.

## Category controls

- The Category control stages multiple membership changes and commits them as one **User Override** only when the user applies them; cancelling commits nothing, while an offline apply updates local presentation and queues encrypted synchronization
- The Category control includes Add New, which opens the same required-name and optional-**Category Description** creation flow used in Settings
- Creating a Custom Category commits independently and preselects it in the open control; cancelling message assignment keeps the new Category but leaves the message unchanged

## Categorization and conflicts

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

- A **Custom Category** may have a **Category Description**
- Deleting a Custom Category removes it from active Mail Views and notification eligibility while preserving historical memberships and learning records as inactive references. An offline edit conflicts rather than recreating the Category silently.
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
