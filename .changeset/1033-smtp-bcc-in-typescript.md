---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now leaves the Bcc field, with its folded lines, out of
the copy it submits through SMTP, and native `imapSend` submits the message as
given. Recipients still see no Bcc recipient, and the Sent copy keeps it.
