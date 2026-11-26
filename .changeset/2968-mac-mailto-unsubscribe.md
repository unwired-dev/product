---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
---

On Mac, a message whose list unsubscribes by email offers Unsubscribe… too: it emails the request from the receiving mailbox through the Outbox, shows it waiting with the Undo Send toast, then sent and dated, refused or unknown, and says when the mailbox must sign in again or receives only. `unsubscribe.email` follows the request's Outbox entry and records a confirmed send for the Mail Profile.
