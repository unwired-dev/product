---
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

Add New Label… to the Mac reader's Gmail Labels submenu: a native alert asks for a name, then the label is created in Gmail and applied to the message. Gmail label creation is a new native write that receives only the label's name, and menu submenus can now group their items.
