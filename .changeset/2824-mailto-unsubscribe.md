---
'@private-email/mail-core': minor
---

Add the Outbox's `unsubscribe`: a confirmed `mailto:` unsubscribe offer becomes an ordinary message from the receiving Mailbox Connection to the offer's one address, with only its subject and body. It waits out the Undo Send Window, is sent and filed in Sent like any message, and leaves the Outbox at Undo without becoming a Draft. A receive-only or unauthorized connection sends nothing and reports `receive-only` or `authorization` A subject holding a run of spaces is now sent in encoded words that keep it, instead of collapsing it (#2824, part of #654).
