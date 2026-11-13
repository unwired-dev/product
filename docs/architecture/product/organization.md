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

## Mute and blocked senders

- New replies do not clear a **Muted Thread**, and rethreading repairs its identity through the stable anchor message without changing provider mail
- `@private-email/mail-core/blocked-senders` stores each **Mail Profile**'s **Blocked Senders** on this device ([#2062](https://github.com/unwired-dev/product/issues/2062)). Each is one plain address: a dot-atom local part and letter, digit and hyphen domain labels, trimmed and compared as a whole without case, as recipient deduplication compares addresses. A display name, bare domain, list, empty or doubled dot or control character is refused, both when blocking and when reading the stored document. It keeps the date it was first blocked, and blocking it again keeps that date. Blocking and unblocking work offline and without a verified Product Sign-In session, and act on one Profile only. A write that storage refuses changes nothing and is reported, so the caller can retry. Private Sync and the Settings list follow in later [#655](https://github.com/unwired-dev/product/issues/655) slices
- Each **Mailbox Connection**'s new Inbox mail, the arrivals New Mail Notifications receive, is screened against its current **Mail Profile**'s **Blocked Senders** before any notification ([#2120](https://github.com/unwired-dev/product/issues/2120)), whether or not its notifications are on. A message whose sender address matches one exactly posts no notification and moves to Trash through the reader's queued, quiet change: Gmail's and Microsoft's Trash, or an IMAP move to the Trash folder the server declares or the person chose when the server moves messages. Without that destination it stays where it is. A device-local receipt naming the connection, the sender address and the time the message was received, which survive a move that renames an IMAP or Microsoft message, is written to the Blocked Senders document before the move is queued, so an arrival reported again, as after a restore to the Inbox, is not moved twice while its receipt is among the newest 1,000 kept. A receipt storage refuses moves nothing. Existing mail is never scanned, and while the Blocked Senders cannot be read every arrival is notified and nothing moves. When more IMAP mail arrives between synchronizations than the Inbox read window holds, only the newest window is screened, as only it is notified; screening the rest is [#2122](https://github.com/unwired-dev/product/issues/2122)

## Category membership

- Legacy single-category assignments migrate idempotently to one-member Category sets while preserving assignment source, override state, and learning signals; mixed-version synchronization remains readable and cannot collapse a multi-category set to one value

## Categorization and conflicts

- The multi-Custom-Category collection activates only after a synchronized minimum-client generation fences legacy singleton clients; updated devices dual-write and merge the legacy definition until every trusted device acknowledges that generation or is revoked, then retire the singleton record

- Deleting a Custom Category writes a synchronized tombstone, removes it from active Mail Views and notification eligibility, and preserves historical message memberships and learning records as inactive references until every trusted device has observed the tombstone; an offline edit conflicts with the tombstone rather than recreating the Category silently
