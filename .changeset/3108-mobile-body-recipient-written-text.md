---
'@private-email/mail-core': minor
'@private-email/mobile': minor
---

On iPhone and iPad, the body's @ also works in written text, where choosing a person replaces only the query with their given name, else display name, else address, and it lists people already in To, Cc or Bcc with their role at the row's trailing edge, keeping that role and never adding them twice. `@private-email/mail-core` drops `bodyRecipientSuggestions`, which `bodySuggestionSections` replaced (#3108).
