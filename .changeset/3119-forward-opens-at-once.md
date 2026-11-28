---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
'@private-email/localization': patch
---

Forward opens its Draft at once on Mac, iPhone and iPad: each original file that isn't downloaded yet shows as importing while the Draft downloads it, and one that couldn't be downloaded is Not added with Try Again. The reader no longer shows Preparing to forward… (#3119).

The `registration-forward` Mock Mail Session lists a message whose attachment downloads after 30 seconds, to show a forward's importing file in native captures.
