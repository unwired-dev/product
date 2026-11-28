---
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On the Mac, More › Message Zoom… and View › Zoom In, Zoom Out and Actual Size zoom the open message alone until it closes, and Use … for All Messages keeps the level as Message zoom. The Command Palette offers the same Zoom In, Zoom Out and Actual Size (mail-core's `zoomCommands`) while the reader shows formatted mail. Show Inbox moves to Shift-Command-0 (#2808).
