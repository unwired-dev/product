---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/macos': minor
---

The Mac composer disables Send while the Draft cannot be sent as it is, and says why before anything is pressed (#2350, part of #2092).

- No recipient shows "Add a recipient to send." under To; text left in To, Cc or Bcc that is not an address shows a warning and "“…” is not a complete address. Correct it to send." under that field, as the approved frame draws it.
- A non-ASCII address, an IMAP mailbox without one Sent folder and a file still importing or failed show their sentence above the body without an announcement. The Command Palette's Send and the Send menu's Send are unavailable too; Remind Me to Send… stays available.
- `Outbox` gains `refusal`, the check Send makes before reading files.
