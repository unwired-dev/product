---
'@private-email/mail-core': patch
---

The Inbox store can read a Gmail connection's Out of Office reply: `outOfOffice()` returns Gmail's vacation responder setting, or why Gmail could not be asked, under the existing Gmail access. An answer that arrives after the mailbox changed or closed is dropped (#3039).
