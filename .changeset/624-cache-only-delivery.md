---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Retry cache-only mailbox authorization before queued delivery after an offline launch, so reconnecting does not require switching apps or waiting for the Inbox poll. Keep a message waiting if verification rejects or leaves its mailbox cache-only, before claiming or handing it off and without blocking later Outbox entries. Defer unknown-message Sent checks after the same failed preparation without reporting a lookup that never happened, and allow a later check without resubmission.
