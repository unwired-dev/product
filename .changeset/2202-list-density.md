---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/localization': minor
---

iPhone and iPad Settings › Appearance chooses each Mail Profile's List density, Comfortable or Compact (#2202, part of #1727).

- Compact lets a Thread-list row's subject wrap and keeps one preview line at every text size.
- `createInboxPreferences` keeps each Profile's Inbox preferences in an encrypted device document and synchronizes them as one sealed `profile-inbox-preferences.` record per Profile, merging each preference's latest choice; native code adds `openInboxPreferences`, `commitInboxPreferences`, `pullInboxPreferences` and `pushInboxPreferences`.
