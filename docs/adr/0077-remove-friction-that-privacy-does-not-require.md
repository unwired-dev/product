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
reads no mail, no provider credential and no Private Sync key. Private Sync stays
end-to-end encrypted. Provider credentials stay on the device that obtained them.

## Decision

**1. A Trusted Device approves a new device by scanning
([#1988](https://github.com/unwired-dev/product/issues/1988)).** The Enrollment
Code keeps its length and entropy. The requesting device also shows it as a QR
code for a Trusted Device to scan, and typed or pasted entry remains. Trusted
Devices receive a push without content when a device asks for approval. What a
Pending Device may do is unchanged.

**2. Unsaved composer edits survive the app ending
([#1989](https://github.com/unwired-dev/product/issues/1989)).** While a composer
is open, its unsaved edits are journaled to an encrypted device-local recovery
record with the protection of a stored Draft. The record is never uploaded or
synchronized. Storing, sending or discarding the message removes it, and so does
closing an empty or unchanged one. After the app ended with a record present, the
next launch offers to restore or discard the message.
What appears in Drafts still follows the explicit Save and Close contract.

**3. The Inbox comes before the Recovery Key, and iCloud Keychain may hold a copy
([#1990](https://github.com/unwired-dev/product/issues/1990)).** Launch lands on
the Inbox once a mailbox is connected. The Recovery Key is a visible reminder that
must be confirmed before another device is approved and before sign-out. When the
person sets up recovery they choose how to keep the key: a copy in iCloud Keychain
beside the printable key, or the key alone. The copy is a synchronizable Keychain
item that never reaches the backend. Choosing it means whoever controls the
person's Apple Account and one of its trusted Apple devices can recover the key;
the choice screen says so. Nothing enables the copy silently. Activating a Device
Revocation deletes the copy and does not write the replacement Recovery Key to iCloud
Keychain, so a removed device that still shares the Apple Account never receives
it. The person may turn the copy on again afterwards, after a warning that every
device signed in to their Apple Account receives it.

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

**7. Withdrawn on 12 Nov 2026: the composer keeps its body-first order
([#1994](https://github.com/unwired-dev/product/issues/1994)).** The review
proposed To, Cc and Bcc, Subject, body, attachments. The product owner confirmed
on 12 Nov 2026 that the existing order is deliberate: body, attachments, Subject,
To, then Cc and Bcc. It stays, and #1994 is closed without a change.

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
for single messages. The reader is unchanged.

**11. Messages keep the sender's responsive layout
([#1355](https://github.com/unwired-dev/product/issues/1355)).** The sanitizer
admits a subset of author `style` blocks: `max-width` media queries with class or
element selectors and the geometry and type properties already allowed inline. It
never admits display, visibility, opacity, color, background or position rules. A
link-only table cell keeps the sender's background when the app verifies its
contrast.

**12. Downloaded attachments stay until evicted
([#2001](https://github.com/unwired-dev/product/issues/2001)).** The 25 MB limit on
one attachment download is lifted up to the provider's message-size limit, with
the transfer streamed to the protected store. The 40 MB bounds on reads that are
still buffered whole stay until those reads are streamed. A downloaded attachment
remains until the store evicts it or its owner is removed, and Storage settings
can clear the store. This follows launch.

**13. A self-hosted mail server may use a pinned certificate
([#2005](https://github.com/unwired-dev/product/issues/2005)).** Unlike the
decisions above, this one accepts a security cost for compatibility. When the
certificate of an IMAP or SMTP endpoint the person entered by hand fails
validation, they may accept that exact certificate as the endpoint's pinned
certificate, after a warning that shows its SHA-256 fingerprint to compare. A
connection has at most one pinned certificate for each of its IMAP and SMTP
endpoints. Every later connection to the endpoint requires exactly that
certificate and counts as **Secure Mail Transport**. A different certificate
fails closed before authentication and offers to replace the pinned certificate,
showing both fingerprints. Each endpoint's fingerprint joins the reviewed
non-secret connection definition of
[ADR 0010](0010-device-local-mailbox-authorization.md) and synchronizes through
Private Sync, so the person's other Trusted Devices require the same certificate
without an unauthenticated first contact of their own. Catalogued or
DNS-discovered endpoints, Gmail and Microsoft never offer a pinned certificate.
TLS 1.2 stays the minimum and no credential is sent before TLS is established.
This follows launch.

## Supersession and retained scope

This ADR supersedes only the clauses named here.

- [ADR 0066](0066-admit-devices-only-through-authorized-enrollment.md): "no
  push is sent" for enrollment requests. Everything a Pending Device may and may
  not do, admission, recovery proof, limits and tombstone protections stand.
- [ADR 0057](0057-present-composing-inside-the-mail-shell.md): the Mac saving
  amendment's acceptance that edits are lost if the app ends, and the same
  consequence of the iPhone and iPad amendment. The explicit Save and Close
  contract stands.
- [ADR 0001](0001-end-to-end-encrypted-product-sync.md) and
  [ADR 0061](0061-separate-product-identity-from-registration-mailbox-authorization.md):
  the user-held Recovery Key as the only fallback when no Trusted Device remains.
  The optional iCloud Keychain copy is a second one. Key custody stays outside
  the backend, and the revocation guarantees of
  [ADR 0020](0020-revoke-devices-with-sync-key-rotation.md) and
  [ADR 0070](0070-seal-key-rotations-to-each-remaining-trusted-device.md) stand:
  a Device Revocation never writes the replacement key to iCloud Keychain, and
  turning the copy on again is the person's explicit, warned choice.
- [ADR 0063](0063-notify-for-new-inbox-mail-without-categorization.md): generic
  content as the default and previews as opt-in. Device evaluation and the
  per-connection switches stand.
- [ADR 0006](0006-local-metadata-search-provider-full-text-search.md) and
  [ADR 0069](0069-expand-the-apple-launch-to-power-user-mail.md): provider search
  only on an explicit request, and in ADR 0069 the generic-by-default and
  optional-preview notification controls. Offline body search, coverage and the
  ban on backend-readable indexing stand.
- [ADR 0029](0029-sanitize-html-before-webkit-rendering.md): removal of every
  author `style` block and of every sender background, and the absence of a
  remote-content choice for one sender beside one-message consent, the device
  policy and the per-connection override. Image admission, Ask as the default,
  link inspection and WebKit isolation stand.
- [ADR 0030](0030-gate-incoming-attachment-downloads.md): the 25 MB limit on one
  attachment download. Explicit download, integrity checks, file protection, the
  evicting store and the 40 MB bounds on buffered reads stand.
- [ADR 0017](0017-require-secure-mail-transport.md) and
  [ADR 0028](0028-restore-tls-1-2-minimum.md): "valid server identity", "rejects
  certificate failures" and "no invalid-certificate override", for a pinned
  certificate on an IMAP or SMTP endpoint the person entered by hand. The TLS 1.2
  minimum, TLS before authentication, the STARTTLS rules and system validation
  of every other connection stand. The **Secure Mail Transport** definition now
  includes a connection to a pinned certificate, so the password rule of
  [ADR 0010](0010-device-local-mailbox-authorization.md) applies to it unchanged.

Decisions 5, 6 and 10 replace behavior that the feature guides describe and
no ADR decided. So do the account page opening before the Inbox while a Recovery
Key is unconfirmed (decision 3), the absence of a notification question in setup
(decision 4), the confirmation before every link (decision 8) and the deletion of
downloaded attachments when the reader closes or the app relaunches (decision 12).

Letting a Pending Device read its own mail before admission was proposed with
decision 1 and is not decided. Trusted Device status gates provider access, the
action queue and the send claim in
[ADR 0010](0010-device-local-mailbox-authorization.md),
[ADR 0015](0015-optimistic-durable-provider-actions.md) and
[ADR 0062](0062-keep-queued-delivery-on-its-originating-device.md), so it needs a
design of its own
([#2010](https://github.com/unwired-dev/product/issues/2010)).

## Consequences

- Approving a second device is a scan, and the approving device is told when one
  is waiting. Until it is approved, the new device still shows no mail.
- Recovery gains a path that depends on the person's Apple Account when they
  choose it. People who decline keep today's guarantee and today's risk of losing
  everything with the key. After a Device Revocation the copy is gone until the
  person turns it on again.
- Accepting a pinned certificate, and every replacement after a certificate
  change, is not authenticated: an attacker on the network at that moment could
  have their own certificate accepted, and Private Sync carries it to every
  Trusted Device. A self-hosted server that renews its certificate, even to a
  publicly valid one, needs its pinned certificate replaced.
- An allowed sender is matched by its From address, which can be forged; a forged
  message from an allowed address loads its remote images.
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
