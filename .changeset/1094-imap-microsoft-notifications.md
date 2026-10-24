---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/mobile': minor
'@private-email/macos': minor
---

Notify privately for newly arrived Inbox mail from IMAP and Microsoft 365 mailboxes too (#1094). Settings › Notifications lists a switch for every mailbox. IMAP notifies for unread mail at or above the last committed UIDNEXT under an unchanged UIDVALIDITY, received no earlier than the previous synchronization began (less five minutes for provider clocks), so older mail moved in never notifies. Microsoft notifies for unread mail a delta page names that this device had not cached; Graph creates moved mail anew in the Inbox, so it counts as created there unless it is older than a full cache. Listings, a UIDVALIDITY change, an expired delta link and updates to known messages never notify. Mark as Read on a notification acts on IMAP and Microsoft mail as on Gmail, and so does Archive, except that on IMAP it needs the server to declare an archive folder and move without expunging other mail; otherwise it changes nothing.
