---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

When Gmail has expired a mailbox's history, the next synchronization asks Gmail again for each online search result and Show Latest message the app holds, and drops those Gmail deleted meanwhile: a search no longer lists a deleted message, and an older invitation stops offering **Show Latest** for a deleted newer revision. Results Gmail still has, and their open reader, stay (#1859).
