---
'@private-email/mobile': patch
'@private-email/macos': patch
'@private-email/mail-core': patch
---

Keep Mac input-method composition keys from executing palette commands. Explain
New Message prerequisites in Inbox and Settings using the current Draft storage
state and sender availability.

Match commands independently of the device's case-folding locale. Successful
commands retain destination focus, while ordinary dismissal keeps pending work
busy until it settles to prevent duplicate execution.
