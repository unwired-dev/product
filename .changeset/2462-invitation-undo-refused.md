---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

On Mac, iPhone and iPad, when storage refuses Undo for a waiting IMAP invitation response, the invitation card says **Couldn’t undo your response** and the Outbox row says _Couldn’t undo. Still waiting to send._, each with an amber warning triangle and **Try Again** in place of **Undo**. The notice clears once the response stops waiting (#2462).
