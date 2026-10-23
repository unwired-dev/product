---
'@private-email/macos': patch
---

Open the Mac composer's Text style, From, actions and Writing tools menus as
native AppKit menus. The system now handles keyboard navigation, Escape and
clicking outside the menu. The current text style and sender are checked, and
Discard is marked destructive. A choice still applies only to the Draft and
window that opened the menu.
