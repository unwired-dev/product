---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

An IMAP mailbox's open Sent folder now shows the copy the app just filed there, without a
pull-down to refresh: once filing succeeds, the Sent folder saved on this device is read again
before the message leaves the Outbox (#2454).
