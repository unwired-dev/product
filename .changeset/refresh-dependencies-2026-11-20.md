---
'@private-email/contracts': patch
'@private-email/convex': patch
'@private-email/draft-editor': patch
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Refresh dependencies to the latest compatible versions: Effect 4.1.5, Convex 1.51, jose 6.2.18, i18next 26.7 and react-i18next 17.1, parse5 8.1, the CSS parser 4.0.3 and Tiptap 3.34 in the Draft editor page. Effect 4.1 grants locks in request order, so a Gmail or Microsoft Inbox history backfill step now steps aside for a synchronization that is waiting, as it did before. No user-visible behavior changes.
