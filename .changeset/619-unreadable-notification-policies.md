---
'@private-email/mail-core': patch
---

Keep unreadable notification policies off for older saved state and refuse changes until synchronized records can be read. Publish the latest learned policy when a change is refused, so an old enabled snapshot cannot keep notifications active.
