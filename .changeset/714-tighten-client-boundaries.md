---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Treat a link the backend refuses, because the identity belongs to another
Product Account or the sign-in is too old, as an expected outcome instead of
logging it as an error. Encode the Inbox seed with its schema before sending it
to native storage.

Flush saved Private Inbox files and their directory to the drive with
`F_FULLFSYNC`, falling back to `fsync` where the file system does not support
it, before a change is reported as saved. Load the Mac Inbox once for all open
windows, at launch and on each activation, instead of once per window.

Stop compiling the test-only synthetic Keychain credential into both apps, and
export the unencrypted mock Inbox storage only from mail-core's testing modules.
