---
'@private-email/macos': minor
'@private-email/localization': patch
---

The Mac reminder menu offers Choose Date and Time… (#2980, part of #658). It opens a popover with AppKit's calendar and time field, starting at the Draft's reminder or tomorrow at 9:00; a time that has passed dims Set Reminder, and Set Reminder stores the chosen time with the Mac's time zone.
