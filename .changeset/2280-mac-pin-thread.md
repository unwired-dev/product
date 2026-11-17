---
'@private-email/localization': patch
'@private-email/mail-core': minor
'@private-email/macos': patch
---

On the Mac, Pin and Unpin a message's Thread from the reader toolbar, the row and reader context menus, VoiceOver's row actions and the Command Palette; every row of a pinned Thread shows a pin and VoiceOver says Pinned. Pins stay on this device and never change a provider flag or star. mail-core adds `pinnedThread`, `subscribe` on the Pins store and the `pin` and `unpin` commands (#2280, part of #2084).
