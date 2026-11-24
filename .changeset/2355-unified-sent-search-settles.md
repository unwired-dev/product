---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Searching a Unified Mailbox such as Sent now settles on its results on the Mac, iPad and
iPhone. Before, the list was rebuilt on every render, so the search asked again which results
had saved bodies and never stopped re-rendering (#2355).
