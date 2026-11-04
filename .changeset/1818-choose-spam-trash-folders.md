---
'@private-email/mobile': patch
'@private-email/localization': patch
'@private-email/mail-core': patch
---

On iPhone and iPad, an IMAP connection left out of All Mail because its server marks no Spam or Trash folder offers Choose Folders… in its notice, a sheet for choosing those folders by name. A ready IMAP Inbox state now reports the Spam and Trash folders its server marks itself as `marked`. A chosen folder no longer takes a role the server marks on several folders, so none of those folders loses it.
