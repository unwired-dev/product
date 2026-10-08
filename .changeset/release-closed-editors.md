---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Release a closed composer from the Draft store, so a window closed while saving
fails no longer stays in memory or follows later conflict copies; its unsaved
edits are still saved.
A pending Close or Discard keeps following its own version until it finishes,
including when its window closes during a conflicting save.
