---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Assemble each host's mail-core stores in `@private-email/mail-core/host`:
`createHost` builds Registration, mailboxes, Drafts, the Outbox, wakes,
freshness and remote content settings over a lazily looked-up native module, and
owns Gmail request cancellation and the device-removed hooks both hosts wrote
twice. Each host looks up `UnwiredRegistration` in one place and restores
Registration and remote content settings once at app start instead of from every
Registration gate mount; push wakes still start on every launch, including
headless ones.
