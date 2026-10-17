---
'@private-email/convex': patch
'@private-email/contracts': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Clients that cannot keep Mail Profiles apart are now fenced out before any Profile is
published. Each device declares its Mail Profile capability. Convex refuses an account's
first Profile record while a Trusted Device has not declared it. Once the account holds
Profile records, it serves Private Sync only to clients that present the capability, so
older builds must upgrade. Creating, renaming, removing or moving into a Profile now
reports why it was refused: an upgrade is required, the Profile still owns a connection,
or another device changed it first.
