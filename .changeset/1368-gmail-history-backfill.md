---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Gmail mailboxes download the metadata of their whole All Mail history in the background once the Inbox is current, 100 messages per page, into encrypted history segments beside the mailbox cache. The download resumes after relaunch or an interrupted page, keeps later Gmail changes, and starts a new pass that keeps the earlier history visible when Gmail's history ID expires. Scrolling past the newest 200 messages of the Inbox or a Gmail view reveals older downloaded mail without asking Gmail, and the Gmail Inbox state reports downloaded messages, Gmail's total and whether the history is complete.
