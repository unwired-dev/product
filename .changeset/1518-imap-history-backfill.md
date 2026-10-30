---
'@private-email/mail-core': patch
---

IMAP mailboxes download the metadata of every selectable folder in the background once the Inbox is current, Inbox first, newest first and at most 500 messages per bounded UID-range read, into encrypted history segments beside the mailbox cache. Each folder's download keeps a durable checkpoint under its UIDVALIDITY and resumes after relaunch or an interrupted read; a changed UIDVALIDITY restarts only that folder. Arrivals during or after the download are added and messages expunged meanwhile are removed. History survives eviction of the bounded opened-folder caches, and the IMAP Inbox state reports downloaded messages, the folders' total and whether the history is complete or paused, which the existing sync status shows.
