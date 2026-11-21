---
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Mac: Send and Send Now with files that were not added (failed, too large, cancelled, interrupted) no longer stay unavailable. They ask “Send without 2 attachments?” in a sheet, naming each file and why, then remove them as one edit and send the rest; **Keep Editing** leaves the Draft as it was (#2598).
