---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now waits with IDLE over a native IMAP session. Native
`imapIdle` takes a session handle and reports the kinds of server events it saw,
and ends when its session closes. TypeScript checks the IDLE capability,
classifies events as a change, the server closing the connection, or neither,
and keeps waiting through other events until its five-minute bound. Stopping a
watch closes its session.
