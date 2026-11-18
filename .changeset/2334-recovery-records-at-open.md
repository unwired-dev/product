---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

Composer recovery keeps the previous run's records as read when the account's storage opens, so a later lock no longer hides them for the rest of the run, and closing a Draft before its record is offered no longer removes the record (#2334, part of #1989).
