---
'@private-email/macos': patch
'@private-email/mobile': patch
---

IMAP mailboxes find a message's Sent copy by its Message-ID instead of a Content-Type search, so Seznam Email, whose server drops the connection on that search, files Sent copies and **Check Again** can confirm a message whose delivery was unknown (#2402).
