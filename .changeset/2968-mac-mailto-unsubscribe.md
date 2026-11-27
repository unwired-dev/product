---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
---

On Mac, a message whose list unsubscribes by email offers Unsubscribe… too: it emails the request from the receiving mailbox through the Outbox, shows it waiting with the Undo Send toast, then sent and dated, refused or unknown, and says when the mailbox must sign in again or receives only. The Outbox keeps the request's Mail Profile and list and records a confirmed send through `unsubscribe.record` before the request leaves it; its Outbox row offers Undo and no Edit.
