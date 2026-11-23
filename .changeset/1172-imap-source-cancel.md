---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Cancelling an IMAP attachment download, or closing a message's last reader while
one downloads, now ends the mail server's transfer of the message source instead
of letting it finish in the background, so a new download can start sooner.
