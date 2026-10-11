---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Register content-free Gmail push wake routes on iPhone, iPad and Mac. After each
verification, native code registers the APNs token with the relay and keeps a
Gmail watch and an opaque route for every verified mailbox, renewing it before
Gmail ends it. Each wake synchronizes only its routed mailbox and completes the
system's handler. Removing a mailbox stops its watch when no other device needs
it and removes its route; sign-out and deletion stop watches first. The Mac's
five-minute interval remains a fallback until every usable mailbox has a verified
route outside the renewal window, and resumes when that coverage is lost.
