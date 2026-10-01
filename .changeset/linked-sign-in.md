---
'@private-email/contracts': minor
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/convex': minor
---

Link Google and Apple as verified alternate sign-ins for one Product Account. Linking reverifies the current sign-in, issues a short-lived single-use ticket bound to the Trusted Device, and completes only after the other identity signs in recently. It never merges accounts, matches by email or turns a Gmail mailbox into a sign-in. Either provider then opens the same account, and `productAccount:connect` reports its Sign-In Providers and rejects reconnects that would reach another account.
