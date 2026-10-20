# New Mail Notifications

Setup, coding rules, validation and observable requirements remain in this file.

[#619](https://github.com/unwired-dev/product/issues/619) adds **New Mail
Notifications** to the maintained iPhone, iPad and Mac clients: a device-evaluated
alert for genuinely new Inbox mail from a Mailbox Connection the person turned on.
The vocabulary lives in the [privacy and sync glossary](domain/privacy-and-sync.md).
No categorization runs: #652 adds Category eligibility, #853 adds quiet hours and
sender or rule filtering, and #908 restyles content, grouping and actions.

## Settings

**Settings › Notifications**, in the Automation group, has two parts.

- **On This Device** shows the operating system's permission: Allowed, Off with
  **Open Settings…** (the system's notification settings for the app), or
  **Allow…**, which asks once. **Show Sender and Subject** is off by default; until
  it is turned on, every notification reads only "New Mail". Permission and this
  choice belong to this device and never synchronize.
- **Per Mailbox** has a switch for each Gmail Mailbox Connection. Every connection
  starts off. Turning one on the first time also asks for permission. The switch is
  a Mail Workflow Preference of the Profile that owns the connection: it
  synchronizes end-to-end encrypted to every Trusted Device as a sealed
  `mailbox-notifications.` record bound to the connection's incarnation. A change
  needs Private Sync and fails closed: offline, or when another device changed it
  first, the stored choice stays and the row says so. Removing and adding a mailbox
  again starts it off. IMAP and Microsoft connections are not listed yet.

## What notifies

Only unread messages that Gmail's history reports as added to the Inbox after the
mailbox finished its first listing notify. A Gmail synchronization that commits a
history page reports that page's new arrivals once, after the commit. A failed or
repeated synchronization therefore reports nothing twice. Listing,
interrupted backfill, listing again after Gmail expired the history, messages moved
back into the Inbox, mail read or archived elsewhere before this device synchronized,
and cache refills never notify. Push wakes, background refresh, activation and the
foreground poll all reach the same synchronization; the content-free push never
decides on its own to alert.

Before posting, the device checks again that the connection still belongs to the same
Product Account and incarnation and that its switch is on. Revoked devices,
removed connections and other Product Accounts therefore post nothing. Each
notification carries only the opaque connection and message identifiers, under an
identifier that replaces rather than repeats an earlier one for the same message.
Removing a connection withdraws its delivered notifications; signing out or a purge
withdraws all of them.

## Opening a notification

On iPhone and iPad a tap opens the message in its connection's current Mail Profile
once Registration admits the mail shell. On the Mac the key Inbox window, or another
open one, comes forward and selects the message in its Inbox. With no window open, a
new one opens. A connection that is gone, or whose Profile is unknown, opens nothing.
Native code queues a tap that launches the app until JavaScript reads it.

## Validate

`packages/mail-core/test/gmail-inbox.test.ts` covers arrival classification and
commit ordering. `host.test.ts` covers gating, permission and generic and preview
content. `mail-profiles.test.ts` covers the synchronized policy and its fail-closed
writes. `notifications.test.ts` covers tap routing. The app suites cover both
Settings pages. `ProductSyncTests.swift` covers sealing the policy record. Native
delivery on iOS, iPadOS and macOS 27, including a tap that launches the app, needs a
build with APNs and a protected Gmail mailbox. It stays a required release check.
