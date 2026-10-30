---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Microsoft mailboxes download the metadata of their Inbox, Sent Items, Archive and own folders in the background once the Inbox is current, 50 messages per page, into encrypted history segments beside the mailbox cache. The download resumes after relaunch or an interrupted page, keeps new, moved, deleted and read mail current through each folder's delta link, and lists a folder again, keeping its earlier history counted, when Graph expires that link. The Microsoft Inbox state reports downloaded messages, the folders' total and whether the history is complete, so the Sync Status Capsule includes it; throttling pauses the download until the next synchronization.
