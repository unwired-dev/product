---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now searches folders in TypeScript over a native IMAP
session: native `imapSearch` searches one examined folder of an open session and
returns its newest matching UIDs and match count, and TypeScript reads their
envelopes, skips folders the server no longer selects or that lack UIDVALIDITY, and
says when folders or older matches were left out.
