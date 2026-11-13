---
'@private-email/mail-core': minor
---

Store each Draft's Send Reminder on this device (#2074, part of #658).

- Native storage keeps the signed-in Product Account's Send Reminders in one encrypted document, replaced only from the revision read; another account reads none and every account purge removes it.
- mail-core gains `createSendReminders` with `reminders`, `remind` and `cancel`, and the host exposes it as `sendReminders`. Reminders are not synchronized, notify nobody and appear in no client yet.
