---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now synchronizes folders in TypeScript over a native IMAP
session: native `imapExamine`, `imapEnvelopes` and `imapFlags` replace
`imapSynchronize`. TypeScript keeps the checkpoint and UIDVALIDITY reset, counts
arrivals from UIDNEXT and the folder's message count, and reads the newest window,
new arrivals and the flags of cached messages. Native code still refuses a folder
without UIDVALIDITY.
