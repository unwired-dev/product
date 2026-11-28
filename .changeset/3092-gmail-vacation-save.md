---
'@private-email/mail-core': patch
---

A Gmail Inbox's new `saveOutOfOffice(change)` saves a change to the mailbox's vacation responder over what Gmail stores now. Fields the change does not name are kept. Without the `gmail.settings.basic` grant, the save answers `permission` and keeps the Inbox open (#3092).
