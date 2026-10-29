---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

IMAP mail can be answered. On iPhone, iPad and Mac the reader offers Reply, Reply All
and Forward for a message from an IMAP connection with verified SMTP, as for Gmail; a
receive-only connection offers none. The Draft sends from the receiving connection
with In-Reply-To and References headers and the quoted correspondence, and Forward
carries the received attachments. Saved IMAP bodies now keep the headers a response
needs; a body saved before them is read from the server again when opened. `ImapInbox`
gains `responseSource`, and a reply's `response.thread` is optional because IMAP has no
conversation to join.
