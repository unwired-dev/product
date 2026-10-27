---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

A valid Gmail connection no longer shows **Gmail needs your permission again**
when the app returns to the foreground during synchronization. While the
foreground account check verifies the connection again, its mailbox and body
reads are pending rather than refused, and the saved Inbox stays shown until the
synchronization after the check. A grant Gmail actually refuses still asks for
Gmail access.
