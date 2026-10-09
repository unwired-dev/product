---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Bound reader translation input while traversing paragraphs and spans, so opening a long message does not join its whole body. Keep an existing translation when only text beyond its captured prefix changes.
