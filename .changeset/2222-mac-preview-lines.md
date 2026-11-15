---
'@private-email/mail-core': minor
'@private-email/macos': minor
'@private-email/localization': minor
---

Mac Settings › Appearance chooses how many preview lines Inbox rows show: None, 1, 2 or 3 (#2222, part of #1727).

- The choice is each Mail Profile's synchronized preview length; the Mac's Settings window sets it for every Profile.
- Inbox rows follow macOS's sidebar icon size, read at launch.
- `createInboxPreferences` adds `previewLines` and `setPreviewLines`.
