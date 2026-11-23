---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

An IMAP mailbox whose server times out while the app checks its account again now stays
offline with its saved mail shown, instead of saying the mail saved on this device can't be
shown. Work that a registration restore invalidates keeps the open IMAP Inbox, which opens
again once the restore ends, as a Gmail Inbox already does (#2731).
