---
'@private-email/mail-core': patch
---

Reload a refused IMAP Inbox after its password is repaired, without restarting
the app. Registration subscribers receive the repaired connection ID only on a
successful IMAP connection, so unrelated registration changes do not retry other
refused mailboxes.
