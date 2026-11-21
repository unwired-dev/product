---
'@private-email/localization': minor
'@private-email/mail-core': minor
'@private-email/macos': patch
'@private-email/mobile': minor
---

Each Trusted Device reports its kind and when it was last active in an end-to-end encrypted
Trusted Device Record (ADR 0079). The Trusted Devices list in the registration snapshot includes
the device in hand, marked `current`, and gives each device its reported `kind` and `activeAt`.
On iPhone and iPad, Account & Devices lists every Trusted Device with its kind's symbol, its name
and "This iPhone" or "This iPad" with Current Device, "Last active …" with the exact time, or
"Added …" with a neutral symbol until the device reports. VoiceOver reads each row as one element
with Remove as its action. The Mac still lists only the devices it can remove (#2607).
