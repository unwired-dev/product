---
'@private-email/mail-core': patch
---

A push wake that launches the app now opens the other connections' saved Inbox listings behind one Trusted Device revocation check instead of one per connection, through the native module's new `openSavedMailboxes`. An Inbox whose saved listing was skipped because another operation, such as an IMAP folder read or Retry of a blocked Gmail change, held it now shows that listing once the operation ends, so the App Icon Badge counts it. Both Inbox stores' `showSaved` take an optional open that several connections share (#2507, part of #1723).
