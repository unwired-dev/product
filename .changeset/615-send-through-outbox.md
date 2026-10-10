---
'@private-email/mail-core': minor
'@private-email/convex': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Send a Draft from the composer on iPhone, iPad and Mac. A sent Draft waits in the
Outbox for a 10-second Undo Send Window, is claimed through Convex under an opaque
identifier so only one Trusted Device can submit it, and is handed to Gmail
as a formatted message with its files, inline images and reply threading. The
Outbox shows messages waiting to send, refused ones to edit, and handed-off ones
whose outcome is unknown, which are never sent again automatically.

A mailbox refresh that prevents handoff keeps the message waiting to retry with
its held claim, as does a retryable Gmail refusal such as a rate limit.

If a mailbox changes its address, the composer keeps the Draft's chosen From
address visible and asks for the mailbox to be chosen again. Queued messages
stop before Gmail handoff if their chosen sender is no longer available.

The composer is read-only while Send is pending and becomes editable again if
admission is refused. Send dismisses any open translation or writing-help preview
and prevents new requests while admission is pending.
