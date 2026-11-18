---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

A composer recovery record keeps the stored version its edits started from (#2332, part of #1989).

- `journal(draft, origin)` stores `origin` as the base of the unsaved version, and `recovered()` returns `{ version, base }` records; a record written before this change returns its version alone.
- The iPhone, iPad and Mac composers journal the version they last stored, leaving it out while that save is pending or failed.
- On the Mac, **Restore** saves against that version, so a Draft another composer saved before the app ended keeps its version and the restored edits become a conflicting copy. A record without one saves against the Draft as listed, as before.
