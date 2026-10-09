---
'@private-email/mail-core': minor
'@private-email/convex': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Send a Draft from the composer on iPhone, iPad and Mac. A sent Draft waits in the
Outbox for a 10-second Undo Send Window, is claimed through Convex under an opaque
identifier so only one Trusted Device can submit it, and is handed to Gmail once
as a formatted message with its files, inline images and reply threading. The
Outbox shows messages waiting to send, refused ones to edit, and handed-off ones
whose outcome is unknown, which are never sent again automatically.
