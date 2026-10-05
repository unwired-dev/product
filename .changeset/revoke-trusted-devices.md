---
'@private-email/convex': minor
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Remove another Trusted Device from the iPhone, iPad and Mac apps. Removal asks for a fresh sign-in and rotates the Product Sync keys, and it replaces the Recovery Key. Remaining devices adopt the new keys. A removed device deletes its account data and credentials when it next connects, including after an Apple relaunch. Saved-account operations check removal before opening sign-in, linking or Recovery Key prompts, so cancelling a prompt cannot retain a removed device's keys or credentials.

Retrying a removal whose reply was lost shows its adopted replacement Recovery Key. A completion notice applies only to that earlier target; choosing another device preserves the key without claiming that device was removed. Confirm the key before starting another removal.
