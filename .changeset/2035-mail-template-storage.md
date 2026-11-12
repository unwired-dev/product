---
'@private-email/mail-core': minor
---

Store each Mail Profile's Mail Templates on this device (#2035, part of #850).

- Native storage keeps the signed-in Product Account's templates in one encrypted document, replaced only from the revision read; another account reads none and every account purge removes it.
- mail-core gains `createMailTemplates` with `templates`, `save` and `remove`, and the host exposes it as `mailTemplates`. Templates are not synchronized yet and no composer offers them.
