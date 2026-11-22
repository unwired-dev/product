---
'@private-email/mobile': patch
'@private-email/macos': patch
---

SwiftMail moves to release 1.18.0. An IMAP search whose server completes without
reporting its matches now fails and can be retried, instead of reading as no
matches. Closing an IMAP session no longer waits for a command still in flight:
the command is cancelled and its connection closes.
