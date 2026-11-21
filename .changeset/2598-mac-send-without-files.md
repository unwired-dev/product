---
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Mac: Send and Send Now with files that were not added (failed, too large, cancelled, interrupted) no longer stays unavailable. It asks “Send without 2 attachments?” in a sheet, naming each file and why, then removes them as one edit and sends the rest; **Keep Editing** leaves the Draft as it was (#2598).
