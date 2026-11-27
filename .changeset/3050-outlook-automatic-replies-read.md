---
'@private-email/mail-core': patch
---

The Inbox store's `outOfOffice()` also reads a Microsoft connection's automatic replies as Graph stores them, or says why Graph could not answer: a 403 for the missing `MailboxSettings.Read` grant is unavailable with the reason `permission` and does not ask for mail access again (#3050).
