---
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On the Mac, once a received attachment is saved to Downloads with **Save As…**, its Profile remembers Downloads on this Mac and the attachment's menu offers **Save to Downloads**, which saves a copy there directly. A name already in Downloads asks to **Keep Both**, **Replace** or **Cancel** (#2664, the last slice of #1681).
