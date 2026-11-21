---
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On the Mac, a downloaded received attachment's menu offers **Save As…**, which opens the system save panel on the reader's window. The reader then shows a toast naming the saved copy and its folder, with **Show in Finder**, or, when nothing was saved, **Couldn’t save to** the chosen folder beneath its header. Cancelling says nothing, and a result is dropped once the reader left the message or storage locked (#2625, part of #1681).
