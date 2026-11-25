---
'@private-email/mail-core': minor
'@private-email/mobile': patch
'@private-email/macos': patch
---

Synchronize each Draft's Send Reminder between the Product Account's Trusted Devices through Private Sync (#2830, part of #658).

- Each reminder is a sealed `send-reminder.` record under an identifier derived from its Mail Profile's and Draft's, holding the Draft and Mail Profile identifiers, the due instant, the time zone and a random write identifier, never Draft content; a removal leaves a sealed tombstone. Native code adds `pullSendReminders` and `pushSendReminder`.
- `createSendReminders` takes an optional `NativeSendReminderSync` and gains `synchronize`. A reminder set, changed or removed offline is published by compare-and-set once Private Sync is reachable. A removal wins over a concurrent change, and of two concurrent changes the first written wins, so devices converge on one reminder. Cancelling a reminder that has not arrived yet is kept until the next pull removes it.
- The Mac and iPhone/iPad mailbox screens synchronize reminders when they open and when the app becomes active or goes to the background, so a reminder removed by Send or Discard on one device is removed on the others.
