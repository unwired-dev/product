---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Starting a Draft that fails unexpectedly, for example because a Draft subscriber
throws, no longer leaves a blank Draft behind. Repeated failed New Message presses
on iPhone, iPad and Mac no longer accumulate empty Drafts that the next save keeps.
