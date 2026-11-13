---
'@private-email/mail-core': minor
---

Store each Mail Profile's Blocked Senders on this device (#2062, part of #655).

- Native storage keeps the signed-in Product Account's Blocked Senders in one encrypted document, replaced only from the revision read; another account reads none and every account purge removes it.
- mail-core gains `createBlockedSenders` with `blockedSenders`, `block` and `unblock`, and the host exposes it as `blockedSenders`. Blocked Senders are not synchronized or enforced yet.
