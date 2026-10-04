---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Never overwrite a Product Sync mailbox descriptor this device cannot open. A
record with a newer schema, a key epoch this device lacks or failed
authentication is left unchanged and not shown; only a missing descriptor or a
readable, different one is replaced.
