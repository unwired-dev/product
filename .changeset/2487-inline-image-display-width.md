---
'@private-email/mail-core': patch
'@private-email/draft-editor': patch
---

An inline image in a Semantic Message Document can carry a display `width` of 320, 640 or 1024 (Small, Medium or Large; Original without one). Formatting, typing, line breaks, Undo, cut and paste and storage keep it, and outgoing HTML gives the image that `width` while sending its original bytes. The Draft editor page carries the width and takes a `resize` command that sets or clears it for every use of one image as one undoable edit (#2487, part of #1735).
