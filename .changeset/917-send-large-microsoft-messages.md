---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Send Microsoft messages larger than Graph's single-request limit, up to 150 MB. Before
its handoff, such a message is saved without its files as an Outlook draft, each file is
attached from native code (through an upload session when it is 3 MB or larger), and the
draft is then sent once with the Outbox's existing claim, Undo Send and uncertain-outcome
rules. A refused or interrupted preparation sends nothing and is tried again, replacing
any draft an interrupted attempt left; an uncertain send is confirmed only from Sent
Items by its Message-ID. The Microsoft too-large message no longer names a 3 MB limit.
