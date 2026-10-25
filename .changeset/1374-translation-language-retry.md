---
'@private-email/mobile': patch
'@private-email/macos': patch
---

When Translation cannot list its languages, the reader and Draft translation say “Translation languages couldn’t be loaded.” with Try Again on Mac, iPhone and iPad; a device without translation languages still says translation is not available.

On Mac, retrying keeps the reader banner visible with Loading languages, a small activity indicator and Try Again disabled. A failed explicit retry is announced in the reader and Draft menu.
