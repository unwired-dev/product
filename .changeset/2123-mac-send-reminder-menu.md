---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/macos': minor
---

Set, change and remove a Draft's Send Reminder from the Mac composer's Send menu (#2123, part of #658).

- A right click on Send opens the Send menu; Remind Me to Send… opens the reminder menu from Send with This Evening (20:00, while still ahead) and Tomorrow Morning (9:00) in the Mac's time zone. Choosing one saves the Draft, keeps the composer open and stores the reminder.
- The composer shows the Draft's reminder in a banner with Change and Remove Reminder, and Send or Discard removes it. A refused write is reported and changes nothing.
- mail-core gains `reminderTimes`, `reminderDay` and `reminderCity`. Reminders still notify nobody and are not synchronized.
