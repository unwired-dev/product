---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Recheck message ownership before showing link confirmations in either host.
Hide invalidated confirmations and reject queued link choices after the message
or account changes, so a previous owner's destination cannot be revealed.
