---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Send from iCloud Mail, Fastmail and other IMAP mailboxes through their SMTP server.
Connecting or entering the password again now verifies SMTP on its own: iCloud Mail
uses STARTTLS on 587 and Fastmail SSL/TLS on 465, and another server's form adds its
SMTP server, port, SSL/TLS or STARTTLS, and an optional separate user name and
password. A mailbox connected before this stays receive only until its password is
entered again.

Messages keep the Outbox's Undo Send, claim and recovery rules. SMTP refusals before
acceptance are kept apart from an uncertain outcome, which is never sent again
automatically. After SMTP accepts a message, a copy with its Bcc field is filed in the
folder the server declares as Sent; filing again after a lost answer or relaunch finds
that copy instead of adding another, and never resends the message. A mailbox whose
server declares no Sent folder cannot send.
