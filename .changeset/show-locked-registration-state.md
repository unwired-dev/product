---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Show a locked state instead of onboarding when the app launches while the device
is locked, and restore the saved account once the app becomes active after
unlock. Restore also verifies unlocked accounts on every activation, preserving
setup feedback when the restored status is unchanged. Only unavailable protected
data is reported as locked; a missing Inbox
key or another Keychain failure is reported as unavailable, since unlocking
cannot recover it.
