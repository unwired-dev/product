---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now plans read-state changes, stars and moves in
TypeScript over a native IMAP session. Native `imapSelect`, `imapFlags`,
`imapStore`, `imapMove`, `imapCopy` and `imapExpunge` replace `imapModify`.
TypeScript checks UIDVALIDITY and presence, chooses MOVE or COPY with
`UID EXPUNGE`, resumes a saved COPYUID without copying again, and treats a
command that failed after it was sent as interrupted.
