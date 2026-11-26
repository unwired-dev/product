---
'@private-email/mail-core': minor
'@private-email/localization': patch
---

A due Send Reminder now posts a notification on the device that set it, at the Show Sender and Subject level of that device and with no actions; changing or removing the reminder, or sending or discarding its Draft, withdraws it. `createHost` returns `followReminderNotifications`, and the native host module declares `scheduleReminderNotifications` (#2990).
