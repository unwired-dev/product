---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Retry cache-only mailbox authorization before queued delivery after an offline launch, so reconnecting does not require switching apps or waiting for the Inbox poll. Keep a message waiting if verification rejects, without blocking later Outbox entries.
