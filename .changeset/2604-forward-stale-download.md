---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

**Forward** and **Attach to New Message** download again an attachment saved before the mailbox's access was renewed, as happens on every Mac activation, and attach the received file. Forward marked it "Not added" and Attach did nothing (#2604, part of #632).
