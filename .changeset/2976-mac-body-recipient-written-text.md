---
'@private-email/mail-core': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

On the Mac, the body's @ also works in written text, where choosing a person replaces only the query with their given name, else display name, else address, and it lists people already in To, Cc or Bcc with their role, keeping that role and never adding them twice. `@private-email/mail-core` adds `bodySuggestionSections` and `recipientRole`, and `addBodyRecipient` takes the `name` it inserts in written text (#2976).
