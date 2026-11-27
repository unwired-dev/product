---
'@private-email/mobile': patch
'@private-email/macos': patch
---

When an IMAP mailbox's mail server refuses the password for an invitation
response, the invitation card offers **Mailbox Settings…** below Accept, Maybe and
Decline. It opens Settings at the mailboxes with that mailbox's password entry
open (#2463).
