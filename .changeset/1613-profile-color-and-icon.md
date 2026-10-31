---
'@private-email/mail-core': minor
'@private-email/macos': patch
'@private-email/mobile': patch
---

Synchronize an optional Mail Profile Color and Icon inside the end-to-end
encrypted Profile record. The registration snapshot's Profile list carries each
Profile's known `color` and `icon`, `createProfile` accepts a style, and the new
`restyleProfile` changes a published Profile's style through compare-and-set or
keeps it for a Profile named offline. Older records and keys this client does
not know read as Graphite and First Letter, and rewrites keep the stored keys.
Duplicate Mail Profile copies the Color and Icon with the name.
