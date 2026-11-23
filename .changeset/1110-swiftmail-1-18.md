---
'@private-email/mobile': patch
'@private-email/macos': patch
---

SwiftMail moves to release 1.18.0. An IMAP search whose server completes without
reporting its matches now fails and can be retried, instead of reading as no
matches. Closing an IMAP session no longer waits for a command still in flight:
the command is cancelled and its connection closes. A server that refuses the
listing of another user's or a shared namespace no longer fails the folder list;
the mail cached under that namespace stays, for now even after its folders are
removed, while only listed folders appear and serve as Sent or Drafts. When the wait for new mail ends,
events the server sends before it acknowledges the end still reach the wait.
