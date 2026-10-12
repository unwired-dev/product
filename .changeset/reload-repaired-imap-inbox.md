---
'@private-email/mail-core': patch
---

Reload an already-open IMAP Inbox after its password is entered again, including
when it is still current, without restarting the app. Registration subscribers
receive the repaired connection ID only on a successful IMAP connection, so
unrelated registration changes do not retry other refused mailboxes.
