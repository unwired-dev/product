---
'@private-email/macos': patch
'@private-email/mobile': patch
---

Connecting an Outlook.com mailbox no longer stops at **Mailbox access was interrupted** after consent: the app accepts the authorization callback Microsoft returns with a trailing slash (#2389).
