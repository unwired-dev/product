---
'@private-email/macos': patch
---

On Mac, a secondary click or Control-click on an Inbox row opens its context menu again. Menus
with a destructive item, such as a row's Delete, showed nothing because their red tint
never reached AppKit.
