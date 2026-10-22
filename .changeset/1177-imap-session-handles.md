---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

The shared IMAP Inbox now reads the folder list through a short-lived native
IMAP session: native `imapOpen`, `imapCapabilities`, `imapListFolders` and
`imapClose` replace `imapFolders`. TypeScript assigns folder roles, recognises
the Inbox and reads the MOVE, UIDPLUS and IDLE capabilities. Native code runs one
command at a time on a session and closes it when TypeScript is done, when it
stays unused, or when its connection generation changes.
