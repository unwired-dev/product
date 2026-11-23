---
'@private-email/mobile': patch
'@private-email/macos': patch
---

An IMAP folder refresh now fails, keeping the previous folder list, when the mail
server's session ends during the listing and the new session reports different
namespaces. Before, one of the ways the mail library logs in again went unnoticed,
and the listing combined folders from both sessions.
