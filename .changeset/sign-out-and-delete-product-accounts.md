---
'@private-email/convex': minor
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Sign out of the current device, or permanently delete the Product Account, from the iPhone, iPad and Mac apps. Each action is confirmed first. Sign-out unregisters the device and its push routes, then removes the account's keys, credentials and session data from the device. Deletion asks for a fresh sign-in: with Apple whenever Sign in with Apple opens the account, so its authorization is revoked, and otherwise with Google. Convex adds a recently authenticated `POST /product-account/delete` route, so Google-only accounts can be deleted. Other devices purge a deleted account when they next reach Convex. Mail in Gmail is never deleted.

Save and confirm an offered Recovery Key before signing out. Interrupted removals stay paused across relaunch and can be retried; acknowledged local cleanup finishes before provider authentication.
