---
'@private-email/mail-core': minor
'@private-email/mobile': patch
'@private-email/macos': patch
---

Open composers show a Send Reminder another device changed (#2897, part of #658).

- `createSendReminders` gains `subscribe`, which tells a listener after each change this device stores, including a reminder a synchronization pass took from another device.
- The Mac and iPhone/iPad composers read their Draft's reminder again on each change, so a reminder another device set, changed or removed appears in, changes in or leaves an open composer's banner as soon as this device synchronizes.
