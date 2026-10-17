---
'@private-email/mobile': patch
'@private-email/macos': patch
---

New Message stays usable when starting a Draft rejects unexpectedly, for example
because a Draft subscriber throws. The Inbox button on iPhone, iPad and Mac and
the compact reader's New Message button reset after the rejection instead of
doing nothing until the view remounts.
