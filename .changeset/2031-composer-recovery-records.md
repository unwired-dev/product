---
'@private-email/mail-core': minor
'@private-email/mobile': patch
'@private-email/macos': patch
---

Keep composer recovery records in device-local encrypted storage (#2031, part of #1989).

- Native storage keeps one encrypted record per composer for the signed-in Product Account. Records stay on this device, never enter the Drafts document or Product Sync, and keep the files and images they name through saves until removed. Removing one needs no key, another account never reads them, and every account purge removes them.
- mail-core Drafts gain `journal`, `forget` and `recovered`. A record refused while storage is locked is written with the next one. The composers do not write records yet.
