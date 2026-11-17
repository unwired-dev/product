---
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

Type @ in an otherwise empty Mac composer body to open Recipient Suggestions
under it. Choosing a person adds them to To and replaces the query with a
greeting, an empty paragraph and the caret, as one undoable edit. Suggestions
come from recent mail of the Draft's Mail Profile and Apple Contacts the app can
already read, without asking for Contacts access.
