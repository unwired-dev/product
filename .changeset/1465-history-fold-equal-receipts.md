---
'@private-email/mail-core': patch
---

Folding recorded changes into downloaded Gmail and Microsoft history no longer
places a changed message whose receipt equals a segment's oldest into that
segment. Such a message may still be held by a later segment the fold has not
read yet, so an unfinished fold step saved it twice: history progress counted
it twice and scrolling could show it twice until the fold finished.
