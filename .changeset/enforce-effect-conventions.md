---
'@private-email/mail-core': minor
---

Run the Persistent Inbox and Registration stores as Effect programs with tagged errors. Storage and registration failures are now logged with their cause; Schema causes name the failing path without its value, so no mail content or account data is logged. Persistent Inbox stores no longer expose `dispose`, and the unused `Mailbox` service, `MockMailbox` layer, `listInbox`, `readMessage` and `MessageNotFound` are removed.
