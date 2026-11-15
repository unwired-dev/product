---
'@private-email/macos': patch
'@private-email/localization': patch
---

Mac Edit › Undo (Command-Z) undoes the key Inbox window's last Archive, Trash or Move, as its Undo notice does (#2188, part of #1993). It stays unavailable while a text field has focus, so the composer body keeps its own Command-Z.
