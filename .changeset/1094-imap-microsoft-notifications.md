---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/mobile': minor
'@private-email/macos': minor
---

Notify privately for newly arrived Inbox mail from IMAP and Microsoft 365 mailboxes too (#1094). Settings › Notifications lists a switch for every mailbox. IMAP notifies for unread mail above the last committed UIDNEXT under an unchanged UIDVALIDITY; Microsoft for unread mail a delta round brings. Listings, a UIDVALIDITY change, an expired delta link, updates to known messages and mail moved back into the Inbox never notify. Archive and Mark as Read on a notification act on IMAP and Microsoft mail as on Gmail.
