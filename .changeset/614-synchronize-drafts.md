---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Synchronize Drafts and their files between a Product Account's Trusted Devices
through End-to-End Encrypted Product Sync. Conflicting edits and edits racing a
deletion are kept as conflict copies, files download verified on first use and
stay visibly incomplete until they do, and Convex stores only sealed records and
file chunks.

Discard retains encrypted cloud assets for offline conflict recovery until Product
Account deletion. Interrupted uploads retry before complete references publish,
and sealed deletion tombstones prevent previously observed records from replaying.
