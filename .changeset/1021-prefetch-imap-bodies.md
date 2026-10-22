---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Recent IMAP mail reads offline without being opened first. After each Inbox
synchronization, iCloud Mail, Fastmail and other IMAP connections save the bodies of
the newest Inbox messages from the last 30 days, within the shared body-cache budget
and with Gmail's prefetch limits, pauses and failure handling. A header-only read
chooses which messages to download, so only single plain-text or HTML messages are
saved and no attachment is downloaded speculatively; other messages stay on demand.
Opening a message waits for its prefetch instead of reading it twice, a new
UIDVALIDITY keeps no body read before it, and local search reports prefetched bodies
as saved. `NativeImapMailbox` gains `imapHeaders`, which the native Registration module
implements over SwiftMail. Body admission accepts an optional `expectedRevision`;
IMAP supplies it so a concurrent metadata commit fences stale body writes atomically.
