---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Read and search mail through an explicit Mail Profile. Each reading view shows
one Profile. Native Mac windows currently open Default; mobile message links can
name another with a `profileId` parameter, retaining it when the reader closes.
Malformed selectors, a connection owned by another Profile, or an unknown Profile
show nothing. `inboxMessages` and `createGmailSearch` now take a `{ profile, mailbox? }`
scope instead of an optional mailbox ID, Inbox listings carry their `profile`, and
`profileMailboxes` lists one Profile's mailboxes. `readingProfile` decodes
absent, malformed and repeated `profileId` selectors. Mobile navigation retains
the window’s Profile through reading, composing and returning to the Inbox. Draft
senders and reader actions consume #646’s connection-Profile boundaries; the
unified Inbox creates Drafts from the window’s Profile. Backend/native Profile
Record Scope routing remains #647 work.

Reader Mail Assistance uses the reading Profile’s device-local consent, including
Translation, and cancels retained work when that consent is revoked or the reading
Profile changes. Account settings and Draft consent retain their staged Default
Profile paths until #647 supplies their ownership and lifecycle.
