---
'@private-email/mail-core': minor
---

A Microsoft Inbox's `saveOutOfOffice({ automaticReplies })` saves a change to the mailbox's automatic replies: only the named fields are sent, and without the `MailboxSettings.ReadWrite` grant the save answers `permission` and keeps the Inbox open. `saveOutOfOffice` now takes its change keyed as the read answers it, so a Gmail change is `{ vacation }` (#3124).
