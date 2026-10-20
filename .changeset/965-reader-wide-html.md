---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Keep wide HTML email readable on iPhone and iPad. Desktop-width tables and blocked
remote image placeholders now narrow to the reader column instead of clipping text
at its right edge, and content that still needs more room, such as unwrappable
text, scrolls sideways inside the message. `decodeMessageContentHeight` is replaced
by `decodeMessageContentSize`, which also returns the measured width.
