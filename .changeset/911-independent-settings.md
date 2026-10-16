---
'@private-email/macos': minor
'@private-email/mobile': minor
'@private-email/localization': patch
---

Settings no longer replaces the Inbox. On the Mac it is one independent window, opened from
the app menu's Settings… (Command-,), the Account button, the Command Palette or an IMAP
password repair; opening it again brings that window forward on the destination asked
for. On iPhone and iPad, Settings covers the Inbox, which stays mounted beneath it and
returns with Open Inbox. Opening Settings no longer closes an open composer, so Drafts,
mailboxes and selected messages are kept, and Settings closes when no Inbox can open.
