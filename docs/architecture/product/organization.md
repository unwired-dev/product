# Organization: architecture notes

Architecture notes for [docs/product/organization.md](../../product/organization.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

These terms include prototype organization features and follow-up work.
References to a feature's first release or v1 retain their original scope.
ADR 0069 and the power-user launch specification identify promoted workflows;
other prototype features do not become implicit launch requirements.

## Decisions and scope

- [Power-user Apple launch scope](../../adr/0069-expand-the-apple-launch-to-power-user-mail.md)
- [Original replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Allow multiple Categories per message](../../adr/0024-allow-multiple-categories-per-message.md)
- [Make Inbox Cleanup reviewed and recoverable](../../adr/0043-make-inbox-cleanup-reviewed-and-recoverable.md)
- [Synchronize Muted Threads as product state](../../adr/0051-synchronize-muted-threads-as-product-state.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Pins

- Legacy message Pins migrate idempotently to their containing **Thread**, deduplicate by **Stable Thread Identity**, and remain until the corresponding Thread **Pin** is durably synchronized; a message without reliable linkage forms a one-message Thread
- `@private-email/mail-core/pins` stores the Product Account's **Pins** on this device ([#2272](https://github.com/unwired-dev/product/issues/2272)). A Pin names the **Mailbox Connection** by its connection ID, which every device derives from the same provider account, and the **Thread** by the identity the provider gives its conversation (Gmail's thread ID, Microsoft's `conversationId`); a message without one, as an IMAP message, is pinned as its own one-message Thread by its message ID. It keeps the date it was first pinned, and pinning it again keeps that date. `pins(connections)` lists only the Pins of the connections it is given, such as a Mail Profile's; unpinning one connection's Thread leaves the same identity pinned in another. Pinning and unpinning work offline and without a verified Product Sign-In session and never change a provider flag or star. A write that storage refuses changes nothing and is reported, so the caller can retry. Hosts subscribe to each change storage keeps. The Mac ([#2280](https://github.com/unwired-dev/product/issues/2280)), iPad and iPhone ([#2343](https://github.com/unwired-dev/product/issues/2343)) offer Pin and Unpin and show the row marker; `pinnedThread` names a message's Thread. **Private Sync** and the Pins mailbox follow in later [#2084](https://github.com/unwired-dev/product/issues/2084) slices

## Mute and blocked senders

- New replies do not clear a **Muted Thread**, and rethreading repairs its identity through the stable anchor message without changing provider mail
- `@private-email/mail-core/blocked-senders` stores each **Mail Profile**'s **Blocked Senders** on this device ([#2062](https://github.com/unwired-dev/product/issues/2062)). Each is one plain address: a dot-atom local part and letter, digit and hyphen domain labels, trimmed and compared as a whole without case, as recipient deduplication compares addresses. A display name, bare domain, list, empty or doubled dot or control character is refused, both when blocking and when reading the stored document. It keeps the date it was first blocked, and blocking it again keeps that date. Blocking and unblocking work offline and without a verified Product Sign-In session, and act on one Profile only. A write that storage refuses changes nothing and is reported, so the caller can retry. Each Profile's Blocked Senders synchronize through **Private Sync** as one sealed record ([#2184](https://github.com/unwired-dev/product/issues/2184)), under an identifier derived from the Profile's, so Convex sees neither the Profile nor a sender address. The record holds each address's latest block or unblock and when it was made; devices merge them address by address, keeping the later change and, at the same instant, the unblock, so an unblock is kept as a tombstone and every device converges whatever order it synchronizes in. A device merges the records when its Inbox opens, returns to the foreground or goes to the background and after each block or unblock, then writes by compare-and-set each record the merge changed, reading again when another device wrote first. A record that does not open here, or names another Profile, changes nothing and is never overwritten. Move counts and receipts stay on the device that moved the mail
- Each **Mailbox Connection**'s new Inbox mail, the arrivals New Mail Notifications receive, is screened against its current **Mail Profile**'s **Blocked Senders** before any notification ([#2120](https://github.com/unwired-dev/product/issues/2120)), whether or not its notifications are on. A message whose sender address matches one exactly posts no notification and moves to Trash through the reader's queued, quiet change: Gmail's and Microsoft's Trash, or an IMAP move to the Trash folder the server declares or the person chose when the server moves messages. Without that destination it stays where it is. A device-local receipt naming the connection, the sender address and the time the message was received, which survive a move that renames an IMAP or Microsoft message, is written to the Blocked Senders document before the move is queued, so an arrival reported again, as after a restore to the Inbox, is not moved twice while its receipt is among the newest 1,000 kept. A receipt storage refuses moves nothing. Existing mail is never scanned, and while the Blocked Senders cannot be read every arrival is notified and nothing moves. When more IMAP mail arrives between synchronizations than the Inbox read window holds ([#2122](https://github.com/unwired-dev/product/issues/2122)), only the newest window is cached and notified, so a burst does not post a notification per message. The envelopes of the older arrivals are read in UID pages of at most one window, newest first, down to the checkpoint, so mail another client expunges meanwhile shifts nothing. That read finishes before the checkpoint advances, and those arrivals are screened like the rest
- On the Mac ([#2141](https://github.com/unwired-dev/product/issues/2141)), a reader's sender menu offers Block Sender… for a sender with one plain address. Its sheet names the exact address, the window's **Mail Profile** and how many of that Profile's loaded messages from it stay where they are; the sender is not told, and a refused write says so. Settings › Blocked Senders lists each Profile's Blocked Senders, newest first, with the date blocked and how many arrivals this device moved to Trash since it was blocked, kept with the Blocked Sender so it outlives the bounded receipts. It reads again after every change the store makes, and − unblocks the selected address
- On iPhone and iPad ([#2166](https://github.com/unwired-dev/product/issues/2166)), a long press on the reader's sender offers Block Sender… after Copy Address. The system alert asks with the same message, and Cancel blocks nothing. Settings › Blocked Senders, under Automation, shows the same list in the system inset list, whose Edit, in the navigation bar on iPhone and beside the title on iPad, and swipe-to-delete unblock one

## Category membership

- Legacy single-category assignments migrate idempotently to one-member Category sets while preserving assignment source, override state, and learning signals; mixed-version synchronization remains readable and cannot collapse a multi-category set to one value

## Categorization and conflicts

- The multi-Custom-Category collection activates only after a synchronized minimum-client generation fences legacy singleton clients; updated devices dual-write and merge the legacy definition until every trusted device acknowledges that generation or is revoked, then retire the singleton record

- Deleting a Custom Category writes a synchronized tombstone, removes it from active Mail Views and notification eligibility, and preserves historical message memberships and learning records as inactive references until every trusted device has observed the tombstone; an offline edit conflicts with the tombstone rather than recreating the Category silently
