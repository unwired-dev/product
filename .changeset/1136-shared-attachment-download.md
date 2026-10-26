---
'@private-email/mail-core': patch
---

Return the running download to every caller that asks for the same received attachment, and let Forward await it instead of watching the Inbox for its state.
