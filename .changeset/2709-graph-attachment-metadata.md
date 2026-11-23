---
'@private-email/mail-core': patch
---

A Microsoft message with attachments now shows its inline images and lists its attachments in the reader. Graph refuses a list of attachments that selects the Content-ID without naming the file attachment type, so the reader kept an image placeholder and no attachment list for every such message (#2709, part of #637).
