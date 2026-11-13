---
'@private-email/localization': minor
'@private-email/mail-core': minor
'@private-email/mobile': minor
---

Set, change and remove a Draft's Send Reminder from the iPhone and iPad composers' Send menu (#2136, part of #658).

- A long press on Send opens its menu; Remind Me to Send… offers This Evening (18:00, while still ahead), Tomorrow Morning (8:00), Next Week (Monday 8:00) and, on iPhone from Sunday to Thursday, This Weekend (Saturday 9:00) in the device's time zone, from mail-core's new `mobileReminderTimes`, in a sheet on iPhone and a popover from Send on iPad. Choosing one saves the Draft, keeps the composer open and stores the reminder.
- The composer shows the Draft's reminder in a banner with Change and Remove Reminder, and Send, Discard or an empty Close removes it. A refused write is reported and changes nothing.
