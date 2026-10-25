---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
'@private-email/localization': patch
---

Removing a mailbox in Settings keeps its confirmation open while the removal runs: Remove shows Removing… with an activity indicator, and Remove and Cancel are disabled. If the mailbox could not be removed, the confirmation stays with a warning, announced to VoiceOver, that says it is still connected and, when this Mac, iPhone or iPad is offline, says so; Remove and Cancel are enabled again. A removal that applied before its reply failed closes as removed.
