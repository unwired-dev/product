---
'@private-email/mail-core': patch
---

Report a Send as admitted when storage holds it, even if removing the last mailbox closed the Drafts meanwhile, and refuse an Outbox message as Not sent when its mailbox was removed and added again since Send, instead of sending it from the new connection.
