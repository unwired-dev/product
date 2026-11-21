---
'@private-email/localization': patch
'@private-email/macos': patch
---

On the Mac, the Send menu (a right click on Send) offers **Send Now**, "No Undo": it sends through the same Outbox checks as Send but without the Undo Send Window, with no confirmation. While a file is still being added, Send Now is dimmed and reads "Send Now — waiting for <file>" (#2594, part of #1674).
