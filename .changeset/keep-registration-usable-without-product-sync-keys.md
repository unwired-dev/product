---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Keep registration and the mailbox usable when this device's Product Sync keys
cannot be read. Restore, sign-in and Gmail authorization now report Product Sync
as unavailable instead of failing and recording a mailbox failure, keep the
unreadable keys unchanged, and log Product Sync errors by domain and code only.
