---
'@private-email/mobile': patch
'@private-email/macos': patch
---

SwiftMail moves to release 1.18.0. An IMAP search whose server completes without
reporting its matches now fails and can be retried, instead of reading as no
matches. Closing an IMAP session no longer waits for a command still in flight:
the command is cancelled and its connection closes. A server that refuses the
listing of another user's or a shared namespace no longer fails the folder list;
the folders cached under that namespace stay. Events an IMAP server sends after the
wait for new mail ends still reach it.
