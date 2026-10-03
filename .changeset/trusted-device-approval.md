---
'@private-email/mail-core': minor
'@private-email/contracts': minor
'@private-email/convex': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

A new device of an existing Product Account asks a Trusted Device for approval and
shows a one-time Enrollment Code. The trusted device seals the account's Product
Sync keys to that device with HPKE, using the code as the pre-shared key. Convex
stores only the request and the sealed approval through the new
`productSyncEnrollment` functions. It refuses replayed, expired, declined,
superseded, revoked and mismatched approvals without touching account keys. The
approved device reads the synchronized mailbox list while Gmail still needs its own
authorization.
