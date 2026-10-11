---
'@private-email/mail-core': minor
---

Give every Mailbox Connection an explicit owning Mail Profile. Connections
recorded before Profiles, which is every connection today, belong to the lossless
Default Profile without changing any connection, Draft, Outbox or encrypted-record
identity. Consumers constructing a decoded `MailboxConnection` must supply its
required `profile`; old-form snapshot JSON remains accepted. Creating another
Profile remains unavailable.
