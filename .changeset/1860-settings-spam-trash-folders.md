---
'@private-email/mobile': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On iPhone and iPad, Settings › Email Accounts lists each IMAP connection whose server leaves Spam or Trash unmarked under Spam and Trash Folders, warning that it is not in All Mail until both are chosen and naming the chosen folders afterwards; Choose Folders… or Change… opens the same folder sheet as the All Mail notice. `@private-email/mail-core/mailboxes` now exports `folderSummary` for that row.
