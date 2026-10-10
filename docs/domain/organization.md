# Mail organization

[Domain index](../../GLOSSARY.md) · [behavior notes](../product/organization.md)

These terms include prototype organization features and follow-up work.
References to a feature's first release or v1 retain their original scope; they
do not add that feature to the focused replacement release.

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**Blocked Sender**:
An exact normalized sender email address whose future arriving messages are moved recoverably to the Mail Provider's Trash on each trusted device that can mutate that Mailbox Connection. The synchronized preference does not retroactively move existing mail, infer aliases, or permanently erase messages.
_Avoid_: Display sender name, domain block, spam report

**Mail View**:
A user-selectable filter within the currently selected mailbox scope that narrows the **Threads** shown without changing mailbox membership or **Message Categories**.
_Avoid_: Category, Mailbox, bottom tab

**All Messages Mail View**:
The permanent **Mail View** that shows every Thread in the selected mailbox scope and is labeled “All” in compact navigation.
_Avoid_: All Mail, All emails

**Catch Up**:
A planned chat-style presentation of the Inbox that shows each message as one bubble with its **Background Message Summary** or preview, except for collapsed category mail. It is an alternative to the message list, not a **Mail View**; see the [Catch Up requirements](../catch-up.md).
_Avoid_: Chat View, group chat, Conversation Feed, digest

**Pin**:
A product-owned marker that keeps a **Thread** in the unified pinned view across trusted devices without changing provider flags.
_Avoid_: Message pin, Gmail star, IMAP flag, provider pin

**Muted Thread**:
A Profile-scoped, product-owned suppression state for a **Thread** that prevents notifications and proactive suggestions without hiding mail, changing unread state, or changing provider mail.
_Avoid_: Provider mute, hidden Thread, notification rule

**Thread Snooze**:
Profile-scoped product state synchronized through **End-to-End Encrypted Product Sync** that hides a Thread from ordinary Inbox until its absolute due instant or a new message arrives. It retains the Thread in Snoozed, All Mail, and Profile-scoped search without changing provider mail.
_Avoid_: Provider snooze, archive, scheduled delivery

**Follow-Up Nudge**:
Profile-scoped encrypted product state for revisiting a sent Thread, created only by explicit scheduling or acceptance of an on-device suggestion. It never drafts or sends mail, is cancelled by a newly observed reply outside the recorded authorized Sending Identity set, and remains visibly overdue when interruption is unavailable.
_Avoid_: Automatic follow-up, Read Receipt, Scheduled Send

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

**Invites**:
A **System Category** for invitations and messages requesting an RSVP.
_Avoid_: Calendar Event Candidate, accepted invitation, calendar entry

**Flights**:
A **System Category** for flight-related messages, including airline itineraries and boarding information.
_Avoid_: All travel, calendar entry

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

**Uncategorized State**:
The state of a message when no **Message Categories** have been assigned, including historical mail that is not automatically categorized.
_Avoid_: Uncategorized category, forced category

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
A proposed Apple Contacts record derived on device from one normalized sender name and email address in message metadata for People-classified direct correspondence with same-connection reply or repeated-correspondence evidence from the owning Mailbox Connection and Thread. Standards-Based Mail accepts bounded RFC encoded names but rejects groups, aliases, and malformed identities. Microsoft Graph and Exchange Web Services preserve provider-native From, Sender, Organizer, and every Reply-To identity as applicable; delegated, aliased, or multiple reply identities fail closed instead of being combined. Phone, organization, postal address, and URL fields may be derived only from a message body already available on the device; detection never fetches a missing body or synchronizes extracted fields.
_Avoid_: Recipient Suggestion, automatically created contact, provider directory entry

**Calendar Event Candidate**:
A proposed local calendar event derived on device from a structured calendar invitation or from an unambiguous date and time in a message body already available on the device. Detection never fetches a missing body or synchronizes extracted event values; ambiguous date, time zone, duration, or location requires native event review.
_Avoid_: Accepted invitation, Invite Message Category, automatically created event

**Feature Suggestion Preference**:
A **Mail Workflow Preference** that enables or suppresses proactive suggestions for exactly one of Inbox Cleanup, Unsubscribe, Add to Contacts, or Add to Calendar.
_Avoid_: Smart Actions setting, device permission, shared feature toggle
