---
'@private-email/macos': patch
'@private-email/mobile': patch
'@private-email/mail-core': patch
---

On the Mac, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, an AppKit sheet for choosing those folders by name with the same rules as iPhone and iPad. `@private-email/mail-core/mailboxes` now exports the shared folder choice model (`folderChoice`, `startingPicks`, `ambiguousFolders`) that both clients render.
