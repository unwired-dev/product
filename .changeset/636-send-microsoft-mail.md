---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Send from Outlook.com and Microsoft 365 mailboxes through Microsoft Graph. Microsoft
mailboxes are now offered in From, and their messages keep the Outbox's Undo Send,
claim and recovery rules: the exact message, with its files, inline images, reply
headers and Bcc, is handed to Graph's sendMail. Only definite non-delivery is retried.
An accepted message leaves the
Outbox; an uncertain one is never sent again automatically and is confirmed only from
one Sent Items copy carrying its own Message-ID. Connecting Microsoft mail now also
asks for `Mail.Send`; a mailbox connected before keeps reading and organizing, and its
first refused send asks for Microsoft again. A Microsoft mailbox sends messages of up
to 3 MB here to fit Graph's 4 MB request limit after base64 encoding.
