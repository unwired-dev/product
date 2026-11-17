---
'@private-email/mail-core': minor
---

Store each pinned Thread on this device (#2272, part of #2084).

- Native storage keeps the signed-in Product Account's Pins in one encrypted document, replaced only from the revision read; another account reads none and every account purge removes it.
- mail-core gains `createPins` with `pins`, `pin` and `unpin`, and the host exposes it as `pins`. Pins are not synchronized or shown yet.
