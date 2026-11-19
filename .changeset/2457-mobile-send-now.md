---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
---

On iPhone and iPad, the Send menu (a long press on Send) offers **Send Now**, "No Undo": it sends through the same Outbox checks as Send but without the Undo Send Window, with no confirmation. While a file is still being added, Send Now is dimmed and says "Waiting for <file> to finish". The Outbox's `send` takes a third `now` argument that admits the message with no Undo Send Window (#2457, part of #1674).
