---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Keep another editor's completed Draft when a stale composer discards, while
discarding the composer's own version even if a late text event arrives during
saving. Preserve destinations chosen during slow New Message creation, retain
the new Draft if its row is selected, and remove only abandoned empty Drafts,
including at the next successful save when storage was locked.
