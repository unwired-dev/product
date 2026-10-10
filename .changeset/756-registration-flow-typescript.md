---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Run the registration flow in TypeScript over a minimal native vault. Restoring,
signing in, switching to and linking sign-ins, verifying and adding Gmail
mailboxes, and the order of sign-out and deletion now run as Effect programs in
`@private-email/mail-core`, which decode every native result and Convex reply.
Native code keeps the saved registration, provider sign-ins, the credential-issuing
connect and the credentials every other Convex call carries; no credential, token
or Google subject crosses the bridge. iPhone, iPad and Mac behave as before.
