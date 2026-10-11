---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Read and search mail through an explicit Mail Profile. Each reading view shows
one Profile. Native Mac windows currently open Default; mobile message links can
name another with a `profile` parameter, retaining it when the reader closes.
Malformed selectors, a connection owned by another Profile, or an unknown Profile
show nothing. `inboxMessages` and `createGmailSearch` now take a `{ profile, mailbox? }`
scope instead of an optional mailbox ID, Inbox listings carry their `profile`, and
`profileMailboxes` lists one Profile's mailboxes. `readingProfile` decodes
legacy and explicit host selectors. Drafts, delivery and
notifications keep their unscoped paths until #646.
