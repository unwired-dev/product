---
'@private-email/mail-core': patch
---

The Inbox store's `outlookCategories()` reads a Microsoft connection's Outlook category list, each name with its colour preset, or says why Graph could not answer: a 403 for the missing `MailboxSettings.Read` grant is unavailable with the reason `permission` and does not ask for mail access again (#3091).
