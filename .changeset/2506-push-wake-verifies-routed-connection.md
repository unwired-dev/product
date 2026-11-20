---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

A Gmail push wake now verifies only the mailbox it synchronizes with its provider. It still checks the Product Account and this Trusted Device, but no longer refreshes every other connection's grant or logs into every IMAP server within the wake's 25 seconds. After a wake that launched the app, the other mailboxes open their saved Inbox until the next activation or background refresh verifies them; in a running app they keep the access they had (#2506).
