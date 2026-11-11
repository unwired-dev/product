---
'@private-email/mail-core': patch
---

The Registration store's `chooseFolders` resolves whether the IMAP connection now holds the
chosen Spam and Trash folders, so the iPhone, iPad and Mac folder sheets no longer check it
themselves.
