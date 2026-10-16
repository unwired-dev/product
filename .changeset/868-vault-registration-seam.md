---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Make the native vault the only seam into Registration: `createRegistration` now
takes the native vault and builds the registration flow itself, and the
Promise-shaped native registration interface is removed. The registration Mock
Mail Session scenarios become presets of the synthetic vault in
`@private-email/mail-core/testing/registration-scenarios`, replacing the separate
`testing/registration-session` fake, so tests run the real registration flow and
Product Sync.
