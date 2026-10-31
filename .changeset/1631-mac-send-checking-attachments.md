---
'@private-email/macos': minor
'@private-email/mail-core': minor
'@private-email/localization': patch
---

Show **Checking…** with an activity indicator on each file of a Mac Draft while
Send checks its bytes. A checked file returns to its size; the first file that
does not verify shows why, such as **Damaged on this device**, and nothing sends
until Send is pressed again. VoiceOver hears **Checking attachments** once.
`outbox.send` accepts an optional `report` callback that receives each step of
the file check as a `SendCheck`.
