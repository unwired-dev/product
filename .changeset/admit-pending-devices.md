---
'@private-email/contracts': minor
'@private-email/convex': minor
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Every device after a Product Account's first now signs in as a Pending Device and joins only when an existing Trusted Device approves its Enrollment Code or the Recovery Key unlocks it. Signing in alone gives a new device no account data, Product Sync, push routing or Gmail authorization. The iPhone, iPad and Mac apps show an enrollment gate instead of "This device cannot join". The gate shows the code with **Check for approval**, offers **Use your Recovery Key**, explains why approval is needed, and allows signing out or deleting the account. A device becomes trusted only after it stores the authorized keys and confirms them.

After a device removal, new devices can join again. The removed device's own identifier stays refused, and under a new identifier it waits like any other device. While the removal's key rotation is pending, only the replacement Recovery Key admits a new device. Convex now publishes a Recovery Key verifier with each recovery envelope, and the unseen-identifier lock and its identifier migration are removed. Pending Devices are limited to one per installation and three per account, and each ends with its Enrollment Code.

Convex also removes the Product Sync reads that needed only a Product Sign-In; all Product Sync reads now require a Trusted Device proof. The legacy Swift client can no longer add a second device.
