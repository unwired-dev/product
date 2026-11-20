---
'@private-email/mobile': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

On iPhone and iPad, touching and holding an inline image's row in the composer offers Small (320 px), Medium (640 px), Large (1024 px) and Original, with a checkmark at the current size, then Remove Image; VoiceOver offers the sizes as actions. A size applies to every use of the image in the body as one Undo step. mail-core adds `imageWidthOf` and `withImageWidth` (#2577, part of #1735).
