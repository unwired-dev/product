---
'@private-email/mobile': patch
'@private-email/macos': patch
---

IMAP reads of message lists, flags and header fields now stop as soon as a mail
server sends more replies than the messages they asked for, or header fields
larger than their budget, instead of keeping everything the server sends.
