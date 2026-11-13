---
'@private-email/mail-core': minor
---

Enforce each Mail Profile's Blocked Senders on newly arriving mail (#2120, part of #655).

- New Inbox mail from a Blocked Sender of its connection's current Mail Profile posts no New Mail Notification and moves to Trash through the reader's queued, quiet change on Gmail, Microsoft and IMAP; without a Trash destination it stays where it is.
- `createBlockedSenders` gains `screen`, which writes a device-local receipt per moved arrival to the Blocked Senders document so an arrival reported again does not move twice while its receipt is among the newest 1,000 kept. `createMailboxes` takes it as `screen`, and Inbox stores' `organize` accepts `{ quiet }`.
