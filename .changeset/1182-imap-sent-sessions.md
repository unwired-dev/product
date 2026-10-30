---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now finds and files Sent copies in TypeScript over a native
IMAP session: native `imapSearch` also matches a Sent copy's MIME boundary in the
Content-Type header, and the new native `imapAppend` appends an Outbox message, read,
to a folder. TypeScript searches the Sent folder for the boundary and appends only when
no copy is there, so a lost answer still never files a second copy. The native
`imapFileSent` and `imapFindSent` operations are removed.
