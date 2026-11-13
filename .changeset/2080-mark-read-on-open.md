---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Mark an unread message read when the reader opens it, on iPhone, iPad and Mac, for Gmail, Microsoft and IMAP mail (#2080). The reader makes the change Mark as read makes once it can change the message, without announcing it or replacing the latest notice and its Undo. Each opening marks the message once, so Mark as unread stands while it stays open. The Gmail and IMAP stores add `readOpened` for this quiet change.
