---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Run device enrollment, Recovery Key recovery, key rotation adoption and Device
Revocation coordination in TypeScript. Requesting and collecting approvals,
approving and declining other devices, unlocking with the Recovery Key, adopting a
removal's key epoch, and preparing, activating, settling and cancelling a removal
now run as Effect programs in `@private-email/mail-core`. Native code keeps every
key operation behind purpose-named steps that store keys, codes and proposals
before anything is sent, and a Draft write refused for an earlier key epoch now
adopts the newer epoch through the shared flow. iPhone, iPad and Mac behave as
before.
