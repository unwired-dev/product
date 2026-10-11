---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Organize and search Microsoft mail. Outlook.com and Microsoft 365 messages can be
marked read or unread, archived, moved to Deleted Items or Junk Email, moved to one
of the mailbox's own folders, and moved back with Undo. Changes are saved on the
device and sent to Microsoft Graph in order, surviving outages, throttling and
relaunch, and a message or folder removed in Outlook shows as Microsoft has it.
Online search covers every folder of each Microsoft mailbox beside Gmail's.

New Microsoft connections ask for `Mail.ReadWrite`. Connections authorized before
keep reading, and ask for Microsoft permission again the first time a change needs
it. Organizing copy names the mailbox's provider instead of always saying Gmail.
