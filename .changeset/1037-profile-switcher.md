---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Add the Profile Switcher to every window's sidebar. Its system menu lists each
Mail Profile with its connections and unread mail, switches only that window,
and names a new Mail Profile, explaining when another device must update first.
The Default Profile appears as Primary Profile. Windows open a targeted link's
Profile, then the one they restore, then the device's Startup Profile: AppKit
restores each Mac window with its Profile, and the iPhone and iPad window
restores the Profile it last showed. Independent iPad scenes remain unimplemented
and are still required by #1037.
