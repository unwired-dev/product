---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
---

On iPhone and iPad a downloaded attachment's context menu is titled with its file name and offers **Save to Files…**, which saves a copy through the system document picker. The reader then shows a toast naming the folder and the copy's file name, with **Show** to open it in Files; cancelling says nothing, and when nothing was saved the reader says so and offers **Save to Files…** again (#2469, part of #1681). The inbox store's `saveAttachmentCopy` resolves the saved copy, `'cancelled'` or `'failed'`.
