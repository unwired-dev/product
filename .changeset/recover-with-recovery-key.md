---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

A device without an available Trusted Device can unlock Product Sync with the
Recovery Key. It reads the account's recovery envelope and opens it only on the
device, then adopts the account keys, withdraws its approval request and reads the
synchronized mailbox list. Gmail still needs its own authorization on that device.
A wrong or foreign key, or an interrupted attempt, preserves encrypted product
data and creates no replacement keys. Recovery renews authentication and may renew
the device's approval request; verified keys saved before an interruption survive
relaunch. The screen explains that losing every
trusted device and the Recovery Key leaves encrypted product data unrecoverable,
and it offers no reset.
