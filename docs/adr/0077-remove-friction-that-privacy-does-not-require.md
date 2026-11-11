---
status: accepted
---

# Remove friction that privacy does not require

## Context

A usability review on 11 Nov 2026
([#1987](https://github.com/unwired-dev/product/issues/1987)) compared the recorded
decisions and the maintained clients with what people expect from a mail client on
iPhone, iPad and Mac. Its main finding was that the largest costs to the person
using the app come from rules stricter than the privacy goal needs, and from
conventions the clients break without a recorded reason. The product owner accepted
the replacements below on 11 Nov 2026. The linked issues own the acceptance
criteria.

The privacy goal these decisions are measured against does not change. The backend
reads no mail, no provider credential and no Product Sync key. Product Sync stays
end-to-end encrypted. Provider credentials stay on the device that obtained them.

## Decision

**1. A Pending Device may use its own mailboxes
([#1988](https://github.com/unwired-dev/product/issues/1988)).** A Pending Device
may obtain Mailbox Authorization for connections it adds and read, send and
organize their mail on that device. Reading mail needs no Product Sync key, so
withholding it protected nothing. A Pending Device still has no Product Sync keys,
synchronized product data, account operations or push routing. Its connections
stay local until admission and are then published to Product Sync. The Enrollment
Code keeps its length and entropy; the requesting device also shows it as a QR
code for a Trusted Device to scan, and typed or pasted entry remains. Trusted
Devices receive a push without content when a device asks for approval.

**2. Unsaved composer edits survive the app ending
([#1989](https://github.com/unwired-dev/product/issues/1989)).** While a composer
is open, its unsaved edits are journaled to an encrypted device-local recovery
record with the protection of a stored Draft. The record is never uploaded or
synchronized. Save Draft, Send and Delete Draft remove it. After the app ended
with a record present, the next launch offers to restore or discard the message.
What appears in Drafts still follows the explicit Save and Close contract.

**3. The Inbox comes before the Recovery Key, and iCloud Keychain may hold a copy
([#1990](https://github.com/unwired-dev/product/issues/1990)).** Launch lands on
the Inbox once a mailbox is connected. The Recovery Key is a visible reminder that
must be confirmed before another device is approved and before sign-out. When the
person sets up recovery they choose how to keep the key: a copy in iCloud Keychain
beside the printable key, or the key alone. The copy is a synchronizable Keychain
item that never reaches the backend. Choosing it means whoever controls the
person's Apple Account and one of its trusted Apple devices can recover the key;
the choice screen says so. Nothing enables the copy silently.

**4. Notifications are offered during setup and name the sender and subject
([#1991](https://github.com/unwired-dev/product/issues/1991)).** When the first
mailbox connects, setup asks once whether to notify about new mail; yes turns that
mailbox's switch on and asks for the system permission. Show Sender and Subject
defaults to on. Content is still built on the device, and the system's preview
setting still governs the lock screen.

**5. Opening a message marks it read
([#1992](https://github.com/unwired-dev/product/issues/1992)).** An explicit open
marks the message read through the action queue. Prefetching never does. A Mark as
Read preference offers Immediately (the default), After 2 seconds and Manually.

**6. Mac shortcuts follow the platform
([#1993](https://github.com/unwired-dev/product/issues/1993)).** Command-N starts a
new message and Option-Command-N opens a new window. Command-P is reserved for
Print, and the Command Palette moves to Command-K. Command-Z undoes the last
organizing action when focus is outside a text field.

**7. The composer starts with its recipients
([#1994](https://github.com/unwired-dev/product/issues/1994)).** The order is To,
Cc and Bcc, Subject, body, attachments. A new message opens with focus in To; a
reply opens with focus in the body. The frames are redrawn and approved before the
change is built.

**8. Only flagged links ask, and remote images can be allowed per sender
([#1995](https://github.com/unwired-dev/product/issues/1995)).** A link that link
inspection does not flag opens directly; a flagged link keeps its confirmation and
states the reason. Beside Load images, the reader offers Always load images from
this sender, a device-local choice for one exact address. Ask stays the default
policy.

**9. One search
([#847](https://github.com/unwired-dev/product/issues/847)).** When the device is
online, a query is sent to the provider automatically after a pause in typing, and
its results appear below the saved ones under their own label. The provider
already holds the mail, and nothing reaches the backend. Coverage labels stay, so
an empty local result never implies that no matching mail exists.

**10. Conversations group in the list
([#846](https://github.com/unwired-dev/product/issues/846)).** The message list
shows one row per Thread by default on every host and provider, with a preference
for single messages. The reader collapses messages already read and offers
newest-first or oldest-first order.

**11. Messages keep the sender's responsive layout
([#1355](https://github.com/unwired-dev/product/issues/1355)).** The sanitizer
admits a subset of author `style` blocks: `max-width` media queries with class or
element selectors and the geometry and type properties already allowed inline. It
never admits display, visibility, opacity, color, background or position rules. A
link-only table cell keeps the sender's background when the app verifies its
contrast.

**12. Downloaded attachments stay until evicted
([#2001](https://github.com/unwired-dev/product/issues/2001)).** The product sets
no download limit below the provider's message-size limit; transfers are streamed
to the protected store. A downloaded attachment remains until the store evicts it
or its owner is removed, and Storage settings can clear the store.

## Supersession and retained scope

This ADR supersedes only the clauses named here.

- [ADR 0066](0066-admit-devices-only-through-authorized-enrollment.md): the
  exclusion of Mailbox Authorization from what a Pending Device may do, and "no
  push is sent" for enrollment requests. Admission to Product Sync, recovery
  proof, limits and tombstone protections stand.
- [ADR 0057](0057-present-composing-inside-the-mail-shell.md): the saving
  amendments' acceptance that edits are lost if the app ends. The explicit Save
  and Close contract stands.
- [ADR 0001](0001-end-to-end-encrypted-product-sync.md) and
  [ADR 0061](0061-separate-product-identity-from-registration-mailbox-authorization.md):
  the user-held Recovery Key as the only fallback when no Trusted Device remains.
  The optional iCloud Keychain copy is a second one. Key custody stays outside
  the backend.
- [ADR 0063](0063-notify-for-new-inbox-mail-without-categorization.md): generic
  content as the default and previews as opt-in. Device evaluation and the
  per-connection switches stand.
- [ADR 0006](0006-local-metadata-search-provider-full-text-search.md) and
  [ADR 0069](0069-expand-the-apple-launch-to-power-user-mail.md): provider search
  only on an explicit request. Offline body search, coverage and the ban on
  backend-readable indexing stand.
- [ADR 0029](0029-sanitize-html-before-webkit-rendering.md): removal of every
  author `style` block and of every sender background. Image admission,
  remote-content consent, link inspection and WebKit isolation stand.
- [ADR 0030](0030-gate-incoming-attachment-downloads.md): the 25 MB download
  limit. Explicit download, integrity checks, file protection and the evicting
  store stand.

Decisions 5, 6, 7 and 10 replace behavior that the feature guides describe and
no ADR decided. So do the account page opening before the Inbox while a Recovery
Key is unconfirmed (decision 3) and the deletion of downloaded attachments when
the reader closes or the app relaunches (decision 12).

## Consequences

- A second device is useful before it is approved, and approving it is a scan.
- Recovery gains a path that depends on the person's Apple Account when they
  choose it. People who decline keep today's guarantee and today's risk of losing
  everything with the key.
- Sender and subject appear in notifications unless the person or the system
  setting hides them.
- Provider search runs without a second action, so queries reach the provider as
  the person types when online.
- Plaintext attachment files live longer on the device, under file protection and
  outside backups.
- The feature guides keep describing current behavior until each issue ships.

## Status and qualification

Accepted as target behavior. Nothing here is implemented or qualified by this
record. Each issue delivers its slice, updates the guide that owns the behavior
and supplies the native and provider evidence.
