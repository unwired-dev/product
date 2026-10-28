---
'@private-email/mobile': patch
'@private-email/macos': patch
---

IMAP folder listing stops reading once a server sends more than 1,000 LIST
responses and closes the session, instead of collecting the whole answer before
refusing it; the oversized list keeps prior cached mail for retry, as before.
SwiftMail moves to the upstream revision that adds this bound. With it, SMTP
connections wait up to five minutes for the server's greeting, as RFC 5321
recommends, instead of five seconds.
