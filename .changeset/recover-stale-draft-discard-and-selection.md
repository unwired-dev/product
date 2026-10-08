---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Recover a stale Draft discard after another storage writer saves, preserving
completed content when an empty composer closes and settling its saving status.
Apply body edits and typing marks at the latest caret even before the composer
redraws. Hide the Drafts heading alongside its rows during received-mail search.
