---
'@private-email/macos': patch
'@private-email/mobile': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On the Mac, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, an AppKit sheet for choosing those folders by name with the same rules as iPhone and iPad. `@private-email/mail-core/mailboxes` now exports the shared folder choice model (`folderChoice`, `startingPicks`, `ambiguousFolders`) that both clients render. When the server marks only one of the two folders, the Mac and iPad sheets are titled "Choose a Spam Folder" or "Choose a Trash Folder", as the frames show; iPhone keeps "Spam Folder" or "Trash Folder".
