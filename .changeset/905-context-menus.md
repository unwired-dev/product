---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
'@private-email/mail-core': patch
---

Add native context menus on Mac, iPad and iPhone (#905): long-press on iPhone and
iPad, pointer secondary click on iPad, and right-click or Control-click on the Mac.

- **Message rows:** Archive, Flag or Unflag, Mark as Read or Unread, and Delete,
  as the row's provider offers them, with Delete last on every platform.
- **Open message:** the reader's header lists Reply, Reply All and Forward (side by
  side on iPhone and iPad), its read state and flag, Move Message with the reader's
  destinations, and Delete Message. The sender offers Copy Address.
- **Links and attachments:** the reader's link list offers Open Link, through the
  usual confirmation, and Copy Link; a downloaded attachment offers Quick Look and
  Share….
